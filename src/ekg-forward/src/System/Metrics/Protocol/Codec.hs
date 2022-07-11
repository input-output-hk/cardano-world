{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.Metrics.Protocol.Codec (
  codecEKGForward
  ) where

import qualified Codec.CBOR.Decoding as CBOR
import qualified Codec.CBOR.Encoding as CBOR
import           Codec.CBOR.Read (DeserialiseFailure)
import           Control.Monad.Class.MonadST (MonadST)
import qualified Data.ByteString.Lazy as LBS
import           Text.Printf (printf)
import           Network.TypedProtocol.Codec.CBOR (Codec, PeerHasAgency (..),
                                                   PeerRole (..), SomeMessage (..),
                                                   mkCodecCborLazyBS)

import           System.Metrics.Protocol.Type

codecEKGForward
  :: forall req resp m.
     (MonadST m)
  => (req -> CBOR.Encoding)
  -> (forall s . CBOR.Decoder s req)
  -> (resp -> CBOR.Encoding)
  -> (forall s . CBOR.Decoder s resp)
  -> Codec (EKGForward req resp)
           DeserialiseFailure m LBS.ByteString
codecEKGForward encodeReq  decodeReq
                encodeResp decodeResp =
  mkCodecCborLazyBS encode decode
 where
  -- Encode messages.
  encode :: forall (pr  :: PeerRole)
                   (st  :: EKGForward req resp)
                   (st' :: EKGForward req resp).
            PeerHasAgency pr st
         -> Message (EKGForward req resp) st st'
         -> CBOR.Encoding

  encode (ClientAgency TokIdle) (MsgReq req) =
    CBOR.encodeListLen 2
      <> CBOR.encodeWord 0
      <> encodeReq req

  encode (ClientAgency TokIdle) MsgDone =
    CBOR.encodeListLen 1
      <> CBOR.encodeWord 1

  encode (ServerAgency TokBusy) (MsgResp resp) =
    CBOR.encodeListLen 2
      <> CBOR.encodeWord 1
      <> encodeResp resp

  -- Decode messages
  decode :: forall (pr :: PeerRole)
                   (st :: EKGForward req resp) s.
            PeerHasAgency pr st
         -> CBOR.Decoder s (SomeMessage st)
  decode stok = do
    len <- CBOR.decodeListLen
    key <- CBOR.decodeWord
    case (key, len, stok) of
      (0, 2, ClientAgency TokIdle) ->
        SomeMessage . MsgReq <$> decodeReq

      (1, 1, ClientAgency TokIdle) ->
        return $ SomeMessage MsgDone

      (1, 2, ServerAgency TokBusy) ->
        SomeMessage . MsgResp <$> decodeResp

      -- Failures per protocol state
      (_, _, ClientAgency TokIdle) ->
        fail (printf "codecEKGForward (%s) unexpected key (%d, %d)" (show stok) key len)
      (_, _, ServerAgency TokBusy) ->
        fail (printf "codecEKGForward (%s) unexpected key (%d, %d)" (show stok) key len)
