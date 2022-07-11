{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}

module System.Metrics.Network.Forwarder
  ( connectToAcceptor
    -- | Export this function for Mux purpose.
  , forwardEKGMetrics
  , forwardEKGMetricsResp
  ) where

import           Codec.CBOR.Term (Term)
import qualified Codec.Serialise as CBOR
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as T
import           Data.Void (Void)
import qualified Network.Socket as Socket
import           Ouroboros.Network.Driver.Limits (ProtocolTimeLimits)
import           Ouroboros.Network.IOManager (withIOManager)
import           Ouroboros.Network.Mux (MiniProtocol (..), MiniProtocolLimits (..),
                                        MiniProtocolNum (..), MuxMode (..),
                                        OuroborosApplication (..), MuxPeer (..),
                                        RunMiniProtocol (..),
                                        miniProtocolLimits, miniProtocolNum, miniProtocolRun)
import           Ouroboros.Network.Protocol.Handshake.Codec (noTimeLimitsHandshake,
                                                             timeLimitsHandshake)
import           Ouroboros.Network.Protocol.Handshake.Type (Handshake)
import           Ouroboros.Network.Protocol.Handshake.Unversioned (UnversionedProtocol (..),
                                                                   UnversionedProtocolData (..),
                                                                   unversionedHandshakeCodec,
                                                                   unversionedProtocolDataCodec)
import           Ouroboros.Network.Protocol.Handshake.Version (acceptableVersion, simpleSingletonVersions)
import           Ouroboros.Network.Snocket (Snocket, localAddressFromPath, localSnocket, socketSnocket)
import           Ouroboros.Network.Socket (connectToNode, nullNetworkConnectTracers)
import qualified System.Metrics as EKG

import           System.Metrics.Configuration (ForwarderConfiguration (..), HowToConnect (..))
import           System.Metrics.Store.Forwarder (mkResponse)
import qualified System.Metrics.Protocol.Forwarder as Forwarder
import qualified System.Metrics.Protocol.Codec as Forwarder

connectToAcceptor
  :: ForwarderConfiguration
  -> EKG.Store
  -> IO ()
connectToAcceptor config@ForwarderConfiguration{..} ekgStore = withIOManager $ \iocp -> do
  let app = forwarderApp config ekgStore
  case acceptorEndpoint of
    LocalPipe localPipe -> do
      let snocket = localSnocket iocp
          address = localAddressFromPath localPipe
      doConnectToAcceptor snocket address noTimeLimitsHandshake app
    RemoteSocket host port -> do
      acceptorAddr:_ <- Socket.getAddrInfo Nothing (Just $ T.unpack host) (Just $ show port)
      let snocket = socketSnocket iocp
          address = Socket.addrAddress acceptorAddr
      doConnectToAcceptor snocket address timeLimitsHandshake app

doConnectToAcceptor
  :: Snocket IO fd addr
  -> addr
  -> ProtocolTimeLimits (Handshake UnversionedProtocol Term)
  -> OuroborosApplication 'InitiatorMode addr LBS.ByteString IO () Void
  -> IO ()
doConnectToAcceptor snocket address timeLimits app =
  connectToNode
    snocket
    unversionedHandshakeCodec
    timeLimits
    unversionedProtocolDataCodec
    nullNetworkConnectTracers
    acceptableVersion
    (simpleSingletonVersions
       UnversionedProtocol
       UnversionedProtocolData
       app)
    Nothing
    address

forwarderApp
  :: ForwarderConfiguration
  -> EKG.Store
  -> OuroborosApplication 'InitiatorMode addr LBS.ByteString IO () Void
forwarderApp config ekgStore =
  OuroborosApplication $ \_connectionId _shouldStopSTM ->
    [ MiniProtocol
        { miniProtocolNum    = MiniProtocolNum 2
        , miniProtocolLimits = MiniProtocolLimits { maximumIngressQueue = maxBound }
        , miniProtocolRun    = forwardEKGMetrics config ekgStore
        }
    ]

forwardEKGMetrics
  :: ForwarderConfiguration
  -> EKG.Store
  -> RunMiniProtocol 'InitiatorMode LBS.ByteString IO () Void
forwardEKGMetrics config ekgStore =
  InitiatorProtocolOnly $
    MuxPeer
      (forwarderTracer config)
      (Forwarder.codecEKGForward CBOR.encode CBOR.decode
                                 CBOR.encode CBOR.decode)
      (Forwarder.ekgForwarderPeer $ mkResponse config ekgStore)

forwardEKGMetricsResp
  :: ForwarderConfiguration
  -> EKG.Store
  -> RunMiniProtocol 'ResponderMode LBS.ByteString IO Void ()
forwardEKGMetricsResp config ekgStore =
  ResponderProtocolOnly $
    MuxPeer
      (forwarderTracer config)
      (Forwarder.codecEKGForward CBOR.encode CBOR.decode
                                 CBOR.encode CBOR.decode)
      (Forwarder.ekgForwarderPeer $ mkResponse config ekgStore)
