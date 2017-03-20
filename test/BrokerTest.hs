{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}
module BrokerTest ( getTestTree ) where

import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Exception
import           Data.Monoid
import           Data.String
import           Control.Monad
import qualified Data.Sequence                      as Seq
import           Data.Typeable
import           Data.UUID                          (UUID)
import           Test.Tasty
import           Test.Tasty.HUnit

import qualified Network.MQTT.Broker                as Broker
import           Network.MQTT.Broker.Authentication
import qualified Network.MQTT.Broker.Session        as Session
import           Network.MQTT.Message
import qualified Network.MQTT.Message               as Message
import qualified Network.MQTT.Trie                  as R

newtype TestAuthenticator = TestAuthenticator (AuthenticatorConfig TestAuthenticator)

instance Authenticator TestAuthenticator where
  data AuthenticatorConfig TestAuthenticator = TestAuthenticatorConfig
    { cfgAuthenticate           :: ConnectionRequest -> IO (Maybe UUID)
    , cfgGetPrincipal           :: UUID -> IO (Maybe Principal)
    }
  data AuthenticationException TestAuthenticator = TestAuthenticatorException deriving (Typeable, Show)
  newAuthenticator = pure . TestAuthenticator
  authenticate (TestAuthenticator cfg) req = cfgAuthenticate cfg req
  getPrincipal (TestAuthenticator cfg) uuid = cfgGetPrincipal cfg uuid

instance Exception (AuthenticationException TestAuthenticator)

getTestTree :: IO TestTree
getTestTree =
  pure $ testGroup "Broker"
    [ testGroup "Authentication"
      [ testCase "Reject with 'ServerUnavaible' when authentication throws exception" $ do
          m1 <- newEmptyMVar
          m2 <- newEmptyMVar
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigNoService
          let sessionRejectHandler                 = putMVar m1
              sessionAcceptHandler session present = putMVar m2 (session, present)
          Broker.withSession broker connectionRequest sessionRejectHandler sessionAcceptHandler
          tryReadMVar m1 >>= \x-> Just ServerUnavailable @?= x
          tryReadMVar m2 >>= \x-> Nothing                @?= x
      , testCase "Reject 'NotAuthorized' when authentication returned Nothing" $ do
          m1 <- newEmptyMVar
          m2 <- newEmptyMVar
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigNoAccess
          let sessionRejectHandler                 = putMVar m1
              sessionAcceptHandler session present = putMVar m2 (session, present)
          Broker.withSession broker connectionRequest sessionRejectHandler sessionAcceptHandler
          tryReadMVar m1 >>= \x-> Just NotAuthorized   @?= x
          tryReadMVar m2 >>= \x-> Nothing              @?= x
      ]
    , testGroup "Subscriptions"

      [ testCase "subscribe the same filter from 2 different sessions" $ do
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigAllAccess
          let req1 = connectionRequest { requestClientIdentifier = "1" }
              req2 = connectionRequest { requestClientIdentifier = "2" }
              msg  = Message.Message "a/b" QoS0 (Retain False) ""
          Broker.withSession broker req1 (const $ pure ()) $ \session1 _ ->
            Broker.withSession broker req2 (const $ pure ()) $ \session2 _ -> do
              Session.subscribe session1 (PacketIdentifier 42) [("a/b", QoS0)]
              Session.subscribe session2 (PacketIdentifier 47) [("a/b", QoS0)]
              Broker.publishDownstream broker msg
              queue1 <- (<>) <$> Session.dequeue session1 <*> Session.dequeue session1
              queue2 <- (<>) <$> Session.dequeue session2 <*> Session.dequeue session2
              queue1 @?= Seq.fromList [ ServerSubscribeAcknowledged (PacketIdentifier 42) [Just QoS0], ServerPublish (PacketIdentifier (-1)) (Duplicate False) msg]
              queue2 @?= Seq.fromList [ ServerSubscribeAcknowledged (PacketIdentifier 47) [Just QoS0], ServerPublish (PacketIdentifier (-1)) (Duplicate False) msg]

      , testCase "get retained message on subscription (newer overrides older, issue #6)" $ do
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigAllAccess
          let req1 = connectionRequest { requestClientIdentifier = "1" }
              msg1 = Message.Message "topic" QoS0 (Retain True) "test"
              msg2 = Message.Message "topic" QoS0 (Retain True) "toast"
          Broker.withSession broker req1 (const $ pure ()) $ \session1 _-> do
            Broker.publishDownstream broker msg1
            Broker.publishDownstream broker msg2
            Session.subscribe session1 (PacketIdentifier 23) [("topic", QoS0)]
            queue1 <- (<>) <$> Session.dequeue session1 <*> Session.dequeue session1
            queue1 @?= Seq.fromList [ ServerSubscribeAcknowledged (PacketIdentifier 23) [Just QoS0], ServerPublish (PacketIdentifier (-1)) (Duplicate False) msg2]

      , testCase "delete retained message when body is empty" $ do
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigAllAccess
          let req1 = connectionRequest { requestClientIdentifier = "1" }
              msg1 = Message.Message "topic" QoS0 (Retain True) "test"
              msg2 = Message.Message "topic" QoS0 (Retain True) ""
          Broker.withSession broker req1 (const $ pure ()) $ \session1 _ -> do
            Broker.publishDownstream broker msg1
            Broker.publishDownstream broker msg2
            Session.subscribe session1 (PacketIdentifier 23) [("topic", QoS0)]
            queue1 <- (<>) <$> Session.dequeue session1 <*> Session.dequeue session1
            queue1 @?= Seq.fromList [ ServerSubscribeAcknowledged (PacketIdentifier 23) [Just QoS0] ]
      ]

    , testGroup "Queue overflow handling"

      [ testCase "Barrel shift on overflowing QoS0 queue" $ do
          let msgs = [ Message.Message "topic" QoS0 (Retain False) (fromString $ show x) | x <- [(1 :: Int)..] ]
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigAllAccess
          t1 <- newEmptyMVar
          t2 <- newEmptyMVar
          t3 <- newEmptyMVar
          t4 <- newEmptyMVar
          t5 <- newEmptyMVar
          let h session _ = do {
              Session.subscribe session (PacketIdentifier 0) [("topic", QoS0)];
              putMVar t1 ();
              takeMVar t2;
              void $ Session.dequeue session; -- subscribe acknowledge
              putMVar t3 =<< Session.dequeue session;
              takeMVar t4;
              putMVar t5 =<< Session.dequeue session;
            }
          let w = Broker.withSession broker connectionRequest (const $ pure ()) h
          withAsync w $ \_-> do
            takeMVar t1
            forM_ (take 10 msgs) $ Broker.publishDownstream broker
            putMVar t2 ()
            p <- takeMVar t3
            assertEqual "Expect 10 packets being dequeued (first time)."
              (Seq.fromList $ fmap (ServerPublish (PacketIdentifier (-1)) (Duplicate False)) $ take 10 msgs) p
            forM_ (take 11 msgs) $ Broker.publishDownstream broker
            putMVar t4 ()
            q <- takeMVar t5
            assertEqual "Expect 10 packets being dequeued (second time)."
              (Seq.fromList $ fmap (ServerPublish (PacketIdentifier (-1)) (Duplicate False)) $ take 10 $ drop 1 msgs) q

      , testCase "Terminate session on overflowing QoS1 queue" $ do
          let msgs = [ Message.Message "topic" QoS1 (Retain False) (fromString $ show x) | x <- [(1 :: Int)..] ]
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigAllAccess
          t1 <- newEmptyMVar
          t2 <- newEmptyMVar
          t3 <- newEmptyMVar
          t4 <- newEmptyMVar
          t5 <- newEmptyMVar
          let h session _ = do {
              Session.subscribe session (PacketIdentifier 0) [("topic", QoS1)];
              putMVar t1 ();
              takeMVar t2;
              putMVar t3 =<< (Seq.drop 1 <$> Session.dequeue session); -- cut off subscribe acknowledge
              void $ takeMVar t4;
              putMVar t5 =<< Session.dequeue session;
            }
          let w = Broker.withSession broker connectionRequest (const $ pure ()) h
          withAsync w $ \as-> do
            takeMVar t1
            forM_ (take 10 msgs) $ Broker.publishDownstream broker
            putMVar t2 ()
            p <- takeMVar t3
            assertEqual "Expect 10 packets being dequeued (first time)."
              (Seq.fromList $ zipWith (\i m-> ServerPublish (PacketIdentifier i) (Duplicate False) m) [0..] $ take 10 msgs) p
            forM_ (take 11 msgs) $ Broker.publishDownstream broker
            assertEqual "Expect session handler thread to be killed." "Left thread killed" =<< (show <$> waitCatch as)

      , testCase "overflowing Qos2 queue (session termination)" $ do
          let msgs = [ Message.Message "topic" QoS2 (Retain False) (fromString $ show x) | x <- [(1 :: Int)..] ]
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigAllAccess
          t1 <- newEmptyMVar
          t2 <- newEmptyMVar
          t3 <- newEmptyMVar
          t4 <- newEmptyMVar
          t5 <- newEmptyMVar
          let h session _ = do {
              Session.subscribe session (PacketIdentifier 0) [("topic", QoS2)];
              putMVar t1 ();
              takeMVar t2;
              putMVar t3 =<< (Seq.drop 1 <$> Session.dequeue session); -- cut off subscribe acknowledge
              void $ takeMVar t4;
              putMVar t5 =<< Session.dequeue session;
            }
          let w = Broker.withSession broker connectionRequest (const $ pure ()) h
          withAsync w $ \as-> do
            takeMVar t1
            forM_ (take 10 msgs) $ Broker.publishDownstream broker
            putMVar t2 ()
            p <- takeMVar t3
            assertEqual "Expect 10 packets being dequeued (first time)."
              (Seq.fromList $ zipWith (\i m-> ServerPublish (PacketIdentifier i) (Duplicate False) m) [0..] $ take 10 msgs) p
            forM_ (take 11 msgs) $ Broker.publishDownstream broker
            assertEqual "Expect session handler thread to be killed." "Left thread killed" =<< (show <$> waitCatch as)
      ]

    , testGroup "Quality of Service"

      [ testCase "transmit a QoS1 message and process acknowledgement" $ do
          let msg = Message.Message "topic" QoS1 (Retain False) "payload"
              pid = PacketIdentifier 0
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigAllAccess
          Broker.withSession broker connectionRequest (const $ pure ()) $ \session _-> do
            pids1 <- Session.getFreePacketIdentifiers session
            Session.enqueueMessage session msg
            queue <- Session.dequeue session
            pids2 <- Session.getFreePacketIdentifiers session
            Session.processPublishAcknowledged session pid
            pids3 <- Session.getFreePacketIdentifiers session
            assertEqual "One packet identifier shall be in use after `dequeue`." (Seq.drop 1 pids1) pids2
            assertEqual "The packet identifier shall have been returned after the message has been acknowledged." pids1 pids3
            assertEqual "The packet is expected in the output queue." (Seq.fromList [ ServerPublish pid (Duplicate False) msg ]) queue

      , testCase "receive a QoS1 message and send acknowledgement" $ do
          let msg = Message.Message "topic" QoS1 (Retain False) "payload"
              pid = PacketIdentifier 0
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigAllAccess
          Broker.withSession broker connectionRequest (const $ pure ()) $ \session _-> do
            Session.subscribe session pid [("topic", QoS0)]
            queue1 <- Session.dequeue session
            assertEqual "A subscribe acknowledgement shall be in the output queue." (Seq.fromList [ ServerSubscribeAcknowledged pid [Just QoS0] ]) queue1
            Session.processPublish session pid (Duplicate False) msg
            queue2 <- Session.dequeue session
            assertEqual "A publish acknowledgment and the (downgraded) message itself shall be in the output queue." (Seq.fromList [ ServerPublishAcknowledged pid ]) queue2
            queue3 <- Session.dequeue session
            assertEqual "The downgraded message queue shall be in the output queue." (Seq.fromList [ ServerPublish (PacketIdentifier (-1)) (Duplicate False) msg { msgQoS = QoS0} ]) queue3

      , testCase "transmit a QoS1 message and retransmit after connection failure" $ do
          let req = connectionRequest { requestCleanSession = False }
              msg = Message.Message "topic" QoS1 (Retain False) "payload"
              pid = PacketIdentifier 0
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigAllAccess
          Broker.withSession broker req (const $ pure ()) $ \session present-> do
            assertEqual "The session shall not be present." (SessionPresent False) present
            Session.enqueueMessage session msg
            queue <- Session.dequeue session
            assertEqual "The message shall be in the output queue." (Seq.fromList [ ServerPublish pid (Duplicate False) msg]) queue
          Broker.withSession broker req (const $ pure ()) $ \session present-> do
            assertEqual "The session shall be present." (SessionPresent True) present
            queue <- Session.dequeue session
            assertEqual "The message shall again be in the output queue, and must not be marked duplicate." (Seq.fromList [ ServerPublish pid (Duplicate True) msg ]) queue

      , testCase "transmit a QoS2 message and process confirmations" $ do
          let msg = Message.Message "topic" QoS2 (Retain False) "payload"
              pid = PacketIdentifier 0
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigAllAccess
          Broker.withSession broker connectionRequest (const $ pure ()) $ \session _-> do
            pids1 <- Session.getFreePacketIdentifiers session
            Session.enqueueMessage session msg
            queue2 <- Session.dequeue session
            pids2 <- Session.getFreePacketIdentifiers session
            assertEqual "One packet identifier shall be in use after `dequeue`." (Seq.drop 1 pids1) pids2
            assertEqual "A PUB packet is expected in the output queue." (Seq.fromList [ ServerPublish pid (Duplicate False) msg ]) queue2
            Session.processPublishReceived session pid
            queue3 <- Session.dequeue session
            pids3 <- Session.getFreePacketIdentifiers session
            assertEqual "The packet identifier shall still be in use." (Seq.drop 1 pids1) pids3
            assertEqual "A PUBREL packet is expected in the output queue." (Seq.fromList [ ServerPublishRelease pid ]) queue3
            Session.processPublishComplete session pid
            pids4 <- Session.getFreePacketIdentifiers session
            assertEqual "The packet identifier shall have been returned after the transaction has been completed." pids1 pids4

      , testCase "transmit a QoS2 message and handle retransmissions on connection failure" $ do
          let req = connectionRequest { requestCleanSession = False }
              msg = Message.Message "topic" QoS2 (Retain False) "payload"
              pid = PacketIdentifier 0
          broker <- Broker.newBroker $ TestAuthenticator authenticatorConfigAllAccess
          Broker.withSession broker req (const $ pure ()) $ \session _-> do
            Session.enqueueMessage session msg
            queue <- Session.dequeue session
            assertEqual "The message shall be in the output queue." (Seq.fromList [ ServerPublish pid (Duplicate False) msg ]) queue
          Broker.withSession broker req (const $ pure ()) $ \session _-> do
            queue <- Session.dequeue session
            assertEqual "The message shall again be in the output queue and must be marked duplicate." (Seq.fromList [ ServerPublish pid (Duplicate True) msg ]) queue
            Session.processPublishReceived session pid
            queue' <- Session.dequeue session
            assertEqual "The release command shall be in the output queue." (Seq.fromList [ ServerPublishRelease pid ]) queue'
          Broker.withSession broker req (const $ pure ()) $ \session _-> do
            queue <- Session.dequeue session
            assertEqual "The release command shall be in the output queue (again)." (Seq.fromList [ ServerPublishRelease pid ]) queue
            Session.processPublishComplete session pid
          Broker.withSession broker req (const $ pure ()) $ \session _-> do
            queue <- Session.dequeue session
            assertEqual "The output queue shall be empty." mempty queue
      ]
    ]

authenticatorConfigNoService :: AuthenticatorConfig TestAuthenticator
authenticatorConfigNoService = TestAuthenticatorConfig
  { cfgAuthenticate           = const $ throwIO TestAuthenticatorException
  , cfgGetPrincipal           = const $ throwIO TestAuthenticatorException
  }

authenticatorConfigNoAccess :: AuthenticatorConfig TestAuthenticator
authenticatorConfigNoAccess  = TestAuthenticatorConfig
  { cfgAuthenticate           = const (pure Nothing)
  , cfgGetPrincipal           = const (pure Nothing)
  }

authenticatorConfigAllAccess :: AuthenticatorConfig TestAuthenticator
authenticatorConfigAllAccess = TestAuthenticatorConfig
  { cfgAuthenticate           = const $ pure (Just uuid)
  , cfgGetPrincipal           = const $ pure (Just pcpl)
  }
  where
    uuid = read "3c7efc50-bff0-4e09-9a9b-0f2bff2db8fc"
    pcpl = Principal {
       principalUsername = Nothing
     , principalQuota = quota
     , principalPublishPermissions = R.singleton "#" ()
     , principalSubscribePermissions = R.singleton "#" ()
     , principalRetainPermissions = R.singleton "#" ()
     }
    quota = Quota {
       quotaMaxIdleSessionTTL    = 60
     , quotaMaxPacketSize        = 65535
     , quotaMaxPacketIdentifiers = 10
     , quotaMaxQueueSizeQoS0     = 10
     , quotaMaxQueueSizeQoS1     = 10
     , quotaMaxQueueSizeQoS2     = 10
     }

connectionRequest :: ConnectionRequest
connectionRequest  = ConnectionRequest
  { requestClientIdentifier = "mqtt-default"
  , requestCleanSession     = True
  , requestSecure           = False
  , requestCredentials      = Nothing
  , requestHttp             = Nothing
  , requestCertificateChain = Nothing
  , requestRemoteAddress    = Nothing
  }
