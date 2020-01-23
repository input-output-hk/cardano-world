{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE UndecidableInstances  #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Ouroboros.Consensus.Node.ProtocolInfo.Byron (
    protocolInfoByron
  , ByronConfig
  , byronConfig
  , PBftSignatureThreshold(..)
  , defaultPBftSignatureThreshold
    -- * Secrets
  , PBftLeaderCredentials
  , PBftLeaderCredentialsError
  , mkPBftLeaderCredentials
  , pbftLeaderOrNot
    -- * For testing
  , plcCoreNodeId
  ) where

import           Control.Exception (Exception (..))
import           Control.Monad.Except
import           Data.Maybe
import qualified Data.Set as Set

import           Cardano.Prelude (Natural)

import           Cardano.Chain.Common (BlockCount (..))
import qualified Cardano.Chain.Delegation as Delegation
import qualified Cardano.Chain.Genesis as Genesis
import qualified Cardano.Chain.Update as Update
import qualified Cardano.Crypto as Crypto

import           Ouroboros.Consensus.BlockchainTime
import           Ouroboros.Consensus.Crypto.DSIGN.Cardano
import           Ouroboros.Consensus.Ledger.Byron
import           Ouroboros.Consensus.Ledger.Extended
import           Ouroboros.Consensus.Node.ProtocolInfo.Abstract
import           Ouroboros.Consensus.NodeId (CoreNodeId)
import           Ouroboros.Consensus.Protocol.Abstract
import           Ouroboros.Consensus.Protocol.PBFT
import qualified Ouroboros.Consensus.Protocol.PBFT.ChainState as CS

{-------------------------------------------------------------------------------
  Credentials
-------------------------------------------------------------------------------}

data PBftLeaderCredentials = PBftLeaderCredentials {
      plcSignKey    :: Crypto.SigningKey
    , plcDlgCert    :: Delegation.Certificate
    , plcCoreNodeId :: CoreNodeId
    } deriving Show

-- | Make the 'PBftLeaderCredentials', with a couple sanity checks:
--
-- * That the block signing key and the delegation certificate match.
-- * That the delegation certificate does correspond to one of the genesis
--   keys from the genesis file.
--
mkPBftLeaderCredentials :: Genesis.Config
                        -> Crypto.SigningKey
                        -> Delegation.Certificate
                        -> Either PBftLeaderCredentialsError
                                  PBftLeaderCredentials
mkPBftLeaderCredentials gc sk cert = do
    guard (Delegation.delegateVK cert == Crypto.toVerification sk)
      ?! NodeSigningKeyDoesNotMatchDelegationCertificate

    let vkGenesis = Delegation.issuerVK cert
    nid <- genesisKeyCoreNodeId gc (VerKeyCardanoDSIGN vkGenesis)
             ?! DelegationCertificateNotFromGenesisKey

    return PBftLeaderCredentials {
      plcSignKey     = sk
    , plcDlgCert     = cert
    , plcCoreNodeId  = nid
    }
  where
    (?!) :: Maybe a -> e -> Either e a
    Just x  ?! _ = Right x
    Nothing ?! e = Left  e

data PBftLeaderCredentialsError =
       NodeSigningKeyDoesNotMatchDelegationCertificate
     | DelegationCertificateNotFromGenesisKey
  deriving (Eq, Show)

instance Exception PBftLeaderCredentialsError where
  displayException = \case
    NodeSigningKeyDoesNotMatchDelegationCertificate ->
      "The signing key does not match the delegation certificate"
    DelegationCertificateNotFromGenesisKey ->
      "Could not find a delegation certificate corresponding to the genesis key"

{-------------------------------------------------------------------------------
  ProtocolInfo
-------------------------------------------------------------------------------}

-- | Signature threshold. This represents the proportion of blocks in a
--   pbftSignatureWindow-sized window which may be signed by any single key.
newtype PBftSignatureThreshold =
        PBftSignatureThreshold { unSignatureThreshold :: Double }

-- | See chapter 4.1 of
--   https://hydra.iohk.io/job/Cardano/cardano-ledger-specs/byronChainSpec/latest/download-by-type/doc-pdf/blockchain-spec
defaultPBftSignatureThreshold :: PBftSignatureThreshold
defaultPBftSignatureThreshold = PBftSignatureThreshold 0.22

protocolInfoByron :: Genesis.Config
                  -> Maybe PBftSignatureThreshold
                  -> Update.ProtocolVersion
                  -> Update.SoftwareVersion
                  -> Maybe PBftLeaderCredentials
                  -> ProtocolInfo ByronBlock
protocolInfoByron genesisConfig mSigThresh pVer sVer mLeader =
    ProtocolInfo {
        pInfoConfig = PBftNodeConfig {
            pbftParams    = byronPBftParams genesisConfig mSigThresh
          , pbftIsLeader  = case mLeader of
                              Nothing   -> PBftIsNotALeader
                              Just cred -> PBftIsALeader $ pbftLeaderOrNot cred
          , pbftExtConfig = byronConfig genesisConfig pVer sVer
          }
      , pInfoInitLedger = ExtLedgerState {
            ledgerState         = initByronLedgerState genesisConfig Nothing
          , ouroborosChainState = CS.empty
          }
      , pInfoInitState  = ()
      }

byronPBftParams :: Genesis.Config -> Maybe PBftSignatureThreshold -> PBftParams
byronPBftParams cfg threshold = PBftParams {
      pbftSecurityParam      = SecurityParam (fromIntegral kParam)
    , pbftNumNodes           = NumCoreNodes . fromIntegral . Set.size
                             . Genesis.unGenesisKeyHashes
                             $ genesisKeyHashes
    , pbftSignatureThreshold = unSignatureThreshold
                             $ fromMaybe defaultPBftSignatureThreshold threshold
    , pbftSlotLength         = slotLengthFromMillisec
                             . (fromIntegral :: Natural -> Integer)
                             . Update.ppSlotDuration
                             . Genesis.configProtocolParameters
                             $ cfg
    }
  where
    Genesis.Config {
        Genesis.configGenesisData =
          Genesis.GenesisData {
            Genesis.gdK                = BlockCount kParam
          , Genesis.gdGenesisKeyHashes = genesisKeyHashes
          }
      } = cfg

pbftLeaderOrNot :: PBftLeaderCredentials -> PBftIsLeader PBftCardanoCrypto
pbftLeaderOrNot (PBftLeaderCredentials sk cert nid) = PBftIsLeader {
      pbftCoreNodeId = nid
    , pbftSignKey    = SignKeyCardanoDSIGN sk
    , pbftDlgCert    = cert
    }

byronConfig :: Genesis.Config
            -> Update.ProtocolVersion
            -> Update.SoftwareVersion
            -> ByronConfig
byronConfig genesisConfig pVer sVer = ByronConfig {
      pbftGenesisConfig   = genesisConfig
    , pbftProtocolVersion = pVer
    , pbftSoftwareVersion = sVer
      -- TODO: Remove these 3 fields
    , pbftProtocolMagic   = Genesis.configProtocolMagic genesisConfig
    , pbftGenesisHash     = Genesis.configGenesisHash genesisConfig
    , pbftEpochSlots      = Genesis.configEpochSlots genesisConfig
    }
