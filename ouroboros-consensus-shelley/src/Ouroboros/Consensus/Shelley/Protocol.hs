{-# LANGUAGE BangPatterns         #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE NamedFieldPuns       #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Transitional Praos.
--
--   Transitional praos allows for the overlaying of Praos with an overlay
--   schedule determining slots to be produced by BFT
module Ouroboros.Consensus.Shelley.Protocol (
    TPraos
  , TPraosChainSelectView (..)
  , TPraosFields (..)
  , TPraosToSign (..)
  , TPraosValidateView
  , TPraosNodeState (..)
  , TPraosParams (..)
  , TPraosProof (..)
  , TPraosIsCoreNode (..)
  , TPraosIsCoreNodeOrNot (..)
  , forgeTPraosFields
  , mkShelleyGlobals
    -- * Crypto
  , Crypto
  , TPraosCrypto
  , TPraosStandardCrypto
    -- * Type instances
  , ConsensusConfig (..)
  ) where

import           Control.Monad.Reader (runReader)
import           Control.Monad.Trans.Except (except)
import           Crypto.Random (MonadRandom)
import           Data.Coerce (coerce)
import           Data.Functor.Identity (Identity)
import qualified Data.Map.Strict as Map
import           Data.Proxy (Proxy (..))
import           Data.Typeable (typeRep)
import           Data.Word (Word64)
import           GHC.Generics (Generic)

import           Cardano.Crypto.DSIGN.Class (VerKeyDSIGN)
import           Cardano.Crypto.KES.Class (SignKeyKES, SignedKES, signedKES)
import qualified Cardano.Crypto.KES.Class as KES
import           Cardano.Crypto.VRF.Class (CertifiedVRF, SignKeyVRF, VerKeyVRF,
                     deriveVerKeyVRF)
import qualified Cardano.Crypto.VRF.Class as VRF
import           Cardano.Prelude (Natural, NoUnexpectedThunks (..))
import           Cardano.Slotting.EpochInfo

import           Ouroboros.Network.Block (BlockNo, pointSlot, unSlotNo)

import           Ouroboros.Consensus.Ledger.Abstract
import qualified Ouroboros.Consensus.Node.State as NodeState
import           Ouroboros.Consensus.Protocol.Abstract
import           Ouroboros.Consensus.Util.Condense

import           Control.State.Transition.Extended (applySTS)
import qualified Control.State.Transition.Extended as STS
import qualified Shelley.Spec.Ledger.API as SL
import qualified Shelley.Spec.Ledger.BaseTypes as SL
import qualified Shelley.Spec.Ledger.BlockChain as SL
import qualified Shelley.Spec.Ledger.Delegation.Certificates as SL
import qualified Shelley.Spec.Ledger.Keys as SL
import qualified Shelley.Spec.Ledger.LedgerState as SL
import qualified Shelley.Spec.Ledger.OCert as SL
import qualified Shelley.Spec.Ledger.STS.Prtcl as STS

import           Ouroboros.Consensus.Shelley.Protocol.Crypto
import           Ouroboros.Consensus.Shelley.Protocol.State (TPraosState)
import qualified Ouroboros.Consensus.Shelley.Protocol.State as State
import           Ouroboros.Consensus.Shelley.Protocol.Util

{-------------------------------------------------------------------------------
  Fields required by TPraos in the header
-------------------------------------------------------------------------------}

data TPraosFields c toSign = TPraosFields {
      tpraosSignature :: SignedKES (KES c) toSign
    , tpraosToSign    :: toSign
    }
  deriving (Generic)

instance (NoUnexpectedThunks toSign, TPraosCrypto c)
  => NoUnexpectedThunks (TPraosFields c toSign)
deriving instance (Show toSign, TPraosCrypto c)
  => Show (TPraosFields c toSign)

-- | Fields arising from transitional praos execution which must be included in
-- the block signature.
data TPraosToSign c = TPraosToSign {
      -- | Verification key for the issuer of this block.
      --
      -- Note that unlike in Classic/BFT where we have a key for the genesis
      -- delegate on whose behalf we are issuing this block, this key
      -- corresponds to the stake pool/core node actually forging the block.
      tpraosToSignIssuerVK :: VerKeyDSIGN (DSIGN c)
    , tpraosToSignVrfVK    :: VerKeyVRF (VRF c)
      -- | Verifiable result containing the updated nonce value.
    , tpraosToSignEta      :: CertifiedVRF (VRF c) SL.Nonce
      -- | Verifiable proof of the leader value, used to determine whether the
      -- node has the right to issue a block in this slot.
      --
      -- We include a value here even for blocks forged under the BFT
      -- schedule. It is not required that such a value be verifiable (though
      -- by default it will be verifiably correct, but unused.)
    , tpraosToSignLeader   :: CertifiedVRF (VRF c) SL.UnitInterval
      -- | Lightweight delegation certificate mapping the cold (DSIGN) key to
      -- the online KES key.
    , tpraosToSignOCert    :: SL.OCert c
    }
  deriving (Generic)

instance TPraosCrypto c => NoUnexpectedThunks (TPraosToSign c)
deriving instance TPraosCrypto c => Show (TPraosToSign c)

-- | Because we are using the executable spec, rather than implementing the
-- protocol directly here, we have a fixed header type rather than an
-- abstraction. So our validate view is fixed to this.
type TPraosValidateView c = SL.BHeader c

{-------------------------------------------------------------------------------
  Forging
-------------------------------------------------------------------------------}

data TPraosNodeState c =
    -- | The online KES key used to sign blocks is available at the given period
    TPraosKeyAvailable !(HotKey c)

    -- | The KES key is being evolved by another thread
    --
    -- Any thread that sees this value should back off and retry.
  | TPraosKeyEvolving

    -- | This node is not a core node, it doesn't have the capability to sign
    -- blocks.
    --
    -- The 'NodeState' of such a node will always be 'TPraosNoKey'.
  | TPraosNoKey
  deriving (Generic)

-- We override 'showTypeOf' to make sure to show @c@
instance TPraosCrypto c => NoUnexpectedThunks (TPraosNodeState c) where
  showTypeOf _ = show $ typeRep (Proxy @(TPraosNodeState c))

forgeTPraosFields :: ( MonadRandom m
                     , TPraosCrypto c
                     , KES.Signable (KES c) toSign
                     )
                  => NodeState.Update m (TPraosNodeState c)
                  -> IsLeader (TPraos c)
                  -> SL.KESPeriod
                  -> (TPraosToSign c -> toSign)
                  -> m (TPraosFields c toSign)
forgeTPraosFields updateNodeState TPraosProof{..} kesPeriod mkToSign = do
    hotKESKey <- evolveKESKeyIfNecessary updateNodeState (SL.KESPeriod kesEvolution)
    let
      signature = signedKES
        ()
        kesEvolution
        (mkToSign signedFields)
        hotKESKey
    return TPraosFields {
        tpraosSignature = signature
      , tpraosToSign    = mkToSign signedFields
      }
  where
    SL.KESPeriod kesPeriodNat = kesPeriod
    SL.OCert _ _ (SL.KESPeriod c0) _ = tpraosIsCoreNodeOpCert

    kesEvolution = if kesPeriodNat >= c0 then kesPeriodNat - c0 else 0

    TPraosIsCoreNode{..} = tpraosIsCoreNode

    SL.VKey issuerVK = tpraosIsCoreNodeColdVerKey

    signedFields = TPraosToSign {
        tpraosToSignIssuerVK = issuerVK
      , tpraosToSignVrfVK    = deriveVerKeyVRF tpraosIsCoreNodeSignKeyVRF
      , tpraosToSignEta      = tpraosEta
      , tpraosToSignLeader   = tpraosLeader
      , tpraosToSignOCert    = tpraosIsCoreNodeOpCert
      }

-- | Get the KES key from the node state, evolve if its KES period doesn't
-- match the given one.
evolveKESKeyIfNecessary
  :: forall m c. (MonadRandom m, TPraosCrypto c)
  => NodeState.Update m (TPraosNodeState c)
  -> SL.KESPeriod -- ^ Relative KES period (to the start period of the OCert)
  -> m (SignKeyKES (KES c))
evolveKESKeyIfNecessary updateNodeState (SL.KESPeriod kesPeriod) = do
    getOudatedKeyOrCurrentKey >>= \case
      Right currentKey -> return currentKey
      Left outdatedKey -> do
        let newKey@(HotKey _ key) = evolveKey outdatedKey
        saveNewKey newKey
        return key
  where
    -- | Return either (@Left@) an outdated key with its current period (setting
    -- the node state to 'TPraosKeyEvolving') or (@Right@) a key that's
    -- up-to-date w.r.t. the current KES period (leaving the node state to
    -- 'TPraosKeyAvailable').
    getOudatedKeyOrCurrentKey
      :: m (Either (HotKey c) (SignKeyKES (KES c)))
    getOudatedKeyOrCurrentKey = NodeState.runUpdate updateNodeState $ \case
      TPraosKeyEvolving ->
        -- Another thread is currently evolving the key; wait
        Nothing
      TPraosKeyAvailable hk@(HotKey kesPeriodOfKey key)
        | kesPeriodOfKey < kesPeriod
          -- Must evolve key
        -> return (TPraosKeyEvolving, Left hk)
        | otherwise
        -> return (TPraosKeyAvailable hk, Right key)
      TPraosNoKey ->
        error "no KES key available"

    -- | Evolve the given key so that its KES period matches @kesPeriod@.
    evolveKey :: HotKey c -> HotKey c
    evolveKey (HotKey oldPeriod outdatedKey) = go outdatedKey oldPeriod kesPeriod
      where
        go !sk c t
          | t < c
          = error "Asked to evolve KES key to old period"
          | c == t
          = HotKey kesPeriod sk
          | otherwise
          = case KES.updateKES () sk c of
              Nothing  -> error "Could not update KES key"
              Just sk' -> go sk' (c + 1) t

    -- | PRECONDITION: we're in the 'TPraosKeyEvolving' node state.
    saveNewKey :: HotKey c -> m ()
    saveNewKey newKey = NodeState.runUpdate updateNodeState $ \case
      TPraosKeyEvolving -> Just (TPraosKeyAvailable newKey, ())
      _                 -> error "must be in evolving state"

{-------------------------------------------------------------------------------
  Protocol proper
-------------------------------------------------------------------------------}

data TPraos c

-- | TPraos parameters that are node independent
data TPraosParams = TPraosParams {
      tpraosEpochInfo         :: !(EpochInfo Identity)
      -- | See 'Globals.slotsPerKESPeriod'.
    , tpraosSlotsPerKESPeriod :: !Word64
      -- | Active slots coefficient. This parameter represents the proportion
      -- of slots in which blocks should be issued. This can be interpreted as
      -- the probability that a party holding all the stake will be elected as
      -- leader for a given slot.
    , tpraosLeaderF           :: !SL.ActiveSlotCoeff
      -- | See 'Globals.securityParameter'.
    , tpraosSecurityParam     :: !SecurityParam
      -- | Maximum number of KES iterations, see 'Globals.maxKESEvo'.
    , tpraosMaxKESEvo         :: !Word64
      -- | Quorum for update system votes and MIR certificates, see
      -- 'Globals.quorum'.
    , tpraosQuorum            :: !Word64
      -- | All blocks invalid after this protocol version, see
      -- 'Globals.maxMajorPV'.
    , tpraosMaxMajorPV        :: !Natural
      -- | Maximum number of lovelace in the system, see
      -- 'Globals.maxLovelaceSupply'.
    , tpraosMaxLovelaceSupply :: !Word64
    }
  deriving (Generic, NoUnexpectedThunks)

data TPraosIsCoreNodeOrNot c
  = TPraosIsACoreNode !(TPraosIsCoreNode c)
  | TPraosIsNotACoreNode
  deriving (Generic, NoUnexpectedThunks)

data TPraosIsCoreNode c = TPraosIsCoreNode {
      -- | Certificate delegating rights from the stake pool cold key (or
      -- genesis stakeholder delegate cold key) to the online KES key.
      tpraosIsCoreNodeOpCert     :: !(SL.OCert c)
    -- | Stake pool cold key or genesis stakeholder delegate cold key.
    , tpraosIsCoreNodeColdVerKey :: !(SL.VKey 'SL.BlockIssuer c)
    , tpraosIsCoreNodeSignKeyVRF :: !(SignKeyVRF (VRF c))
    }
  deriving (Generic)

instance Crypto c => NoUnexpectedThunks (TPraosIsCoreNode c)

-- | Assembled proof that the issuer has the right to issue a block in the
-- selected slot.
data TPraosProof c = TPraosProof {
      tpraosEta        :: CertifiedVRF (VRF c) SL.Nonce
    , tpraosLeader     :: CertifiedVRF (VRF c) SL.UnitInterval
    , tpraosIsCoreNode :: TPraosIsCoreNode c
    }
  deriving (Generic)

instance TPraosCrypto c => NoUnexpectedThunks (TPraosProof c)

-- | Static configuration
data instance ConsensusConfig (TPraos c) = TPraosConfig {
      tpraosParams          :: !TPraosParams
    , tpraosIsCoreNodeOrNot :: !(TPraosIsCoreNodeOrNot c)
    }
  deriving (Generic)

-- Use generic instance
instance TPraosCrypto c => NoUnexpectedThunks (ConsensusConfig (TPraos c))

-- | View of the ledger tip for chain selection.
--
--   We order between chains as follows:
--   - By chain length, with longer chains always preferred; _else_
--   - If the tip of each chain was issued by the same agent, then we prefer the
--     chain whose tip has the highest ocert issue number, if one exists; _else_
--   - All chains are considered equally preferable
data TPraosChainSelectView c = ChainSelectView {
    csvChainLength :: BlockNo
  , csvIssuer      :: SL.VKey 'SL.BlockIssuer c
  , csvIssueNo     :: Natural
  } deriving Eq

instance Crypto c => Ord (TPraosChainSelectView c) where
  compare (ChainSelectView l1 i1 in1) (ChainSelectView l2 i2 in2) =
    compare l1 l2 <> if i1 == i2 then compare in1 in2 else EQ

instance TPraosCrypto c => ChainSelection (TPraos c) where

  -- | Chain selection is done on the basis of the chain length first, and then
  -- operational certificate issue number.
  type SelectView (TPraos c) = TPraosChainSelectView c

instance TPraosCrypto c => ConsensusProtocol (TPraos c) where
  type ConsensusState  (TPraos c) = TPraosState c
  type IsLeader        (TPraos c) = TPraosProof c
  type LedgerView      (TPraos c) = SL.LedgerView c
  type ValidationErr   (TPraos c) = [[STS.PredicateFailure (STS.PRTCL c)]]
  type ValidateView    (TPraos c) = TPraosValidateView c

  protocolSecurityParam = tpraosSecurityParam . tpraosParams

  checkIfCanBeLeader TPraosConfig{tpraosIsCoreNodeOrNot} =
    case tpraosIsCoreNodeOrNot of
      TPraosIsACoreNode{}  -> True
      TPraosIsNotACoreNode -> False

  checkIsLeader cfg@TPraosConfig{..} (Ticked slot lv) cs =
    case tpraosIsCoreNodeOrNot of
      TPraosIsNotACoreNode          -> return Nothing
      TPraosIsACoreNode isACoreNode -> go isACoreNode
    where

      -- | Check whether we have an operational certificate valid for the
      -- current KES period.
      hasValidOCert :: TPraosIsCoreNode c -> Bool
      hasValidOCert TPraosIsCoreNode{tpraosIsCoreNodeOpCert} =
          kesPeriod >= c0 && kesPeriod < c1
        where
          SL.OCert _ _ (SL.KESPeriod c0) _ = tpraosIsCoreNodeOpCert
          c1 = c0 + fromIntegral (tpraosMaxKESEvo tpraosParams)
          -- The current KES period
          kesPeriod = fromIntegral $
            unSlotNo slot `div` tpraosSlotsPerKESPeriod tpraosParams

      go :: MonadRandom m => TPraosIsCoreNode c -> m (Maybe (TPraosProof c))
      go icn = do
        let TPraosIsCoreNode {
                tpraosIsCoreNodeColdVerKey
              , tpraosIsCoreNodeSignKeyVRF
              } = icn
            prtclState = State.currentPRTCLState cs
            eta0       = prtclStateEta0 prtclState
            vkhCold    = SL.hashKey tpraosIsCoreNodeColdVerKey
            rho'       = SL.mkSeed SL.seedEta slot eta0
            y'         = SL.mkSeed SL.seedL   slot eta0
        rho <- VRF.evalCertified () rho' tpraosIsCoreNodeSignKeyVRF
        y   <- VRF.evalCertified () y'   tpraosIsCoreNodeSignKeyVRF
        -- First, check whether we're in the overlay schedule
        return $ case Map.lookup slot (SL.lvOverlaySched lv) of
          Nothing
            | meetsLeaderThreshold cfg lv (SL.coerceKeyRole vkhCold) y
            , hasValidOCert icn
              -- Slot isn't in the overlay schedule, so we're in Praos
            -> Just TPraosProof {
                 tpraosEta        = coerce rho
               , tpraosLeader     = coerce y
               , tpraosIsCoreNode = icn
               }
            | otherwise
            -> Nothing

          -- This is a non-active slot; nobody may produce a block
          Just SL.NonActiveSlot -> Nothing

          -- The given genesis key has authority to produce a block in this
          -- slot. Check whether we're its delegate.
          Just (SL.ActiveSlot gkhash) -> case Map.lookup gkhash dlgMap of
              Just dlgHash
                | SL.coerceKeyRole dlgHash == vkhCold
                , hasValidOCert icn
                -> Just TPraosProof {
                    tpraosEta        = coerce rho
                    -- Note that this leader value is not checked for slots in
                    -- the overlay schedule, so we could set it to whatever we
                    -- want. We evaluate it as normal for simplicity's sake.
                  , tpraosLeader     = coerce y
                  , tpraosIsCoreNode = icn
                  }
              _ -> Nothing
            where
              SL.GenDelegs dlgMap = SL.lvGenDelegs lv

  updateConsensusState TPraosConfig{..} (Ticked _ lv) b cs = do
      newCS <- except . flip runReader shelleyGlobals $
        applySTS @(STS.PRTCL c) $ STS.TRC (prtclEnv, prtclState, b)
      return
        $ State.prune (fromIntegral k)
        $ State.append slot newCS cs
    where
      slot = SL.bheaderSlotNo $ SL.bhbody b
      prevHash = SL.bheaderPrev $ SL.bhbody b
      epochInfo = tpraosEpochInfo tpraosParams
      SecurityParam k = tpraosSecurityParam tpraosParams
      shelleyGlobals = mkShelleyGlobals tpraosParams

      prtclEnv :: STS.PrtclEnv c
      prtclEnv = SL.mkPrtclEnv
        lv
        (isNewEpoch epochInfo slot (State.lastSlot cs))
        (SL.prevHashToNonce prevHash)

      prtclState :: STS.PrtclState c
      prtclState = State.currentPRTCLState cs

  -- Rewind the chain state
  --
  -- We don't roll back to the exact slot since that slot might not have been
  -- filled; instead we roll back the the block just before it.
  rewindConsensusState _proxy _k = State.rewind . pointSlot

mkShelleyGlobals :: TPraosParams -> SL.Globals
mkShelleyGlobals TPraosParams {..} = SL.Globals {
      epochInfo                     = tpraosEpochInfo
    , slotsPerKESPeriod             = tpraosSlotsPerKESPeriod
    , stabilityWindow               = ceiling $ 3 * (toRational f / fromIntegral k)
    , randomnessStabilisationWindow = ceiling $ 4 * (toRational f / fromIntegral k)
    , securityParameter             = k
    , maxKESEvo                     = tpraosMaxKESEvo
    , quorum                        = tpraosQuorum
    , maxMajorPV                    = tpraosMaxMajorPV
    , maxLovelaceSupply             = tpraosMaxLovelaceSupply
    , activeSlotCoeff               = tpraosLeaderF
    }
  where
    SecurityParam k = tpraosSecurityParam
    f = SL.intervalValue . SL.activeSlotVal $ tpraosLeaderF

-- | Check whether this node meets the leader threshold to issue a block.
meetsLeaderThreshold
  :: forall c.
     ConsensusConfig (TPraos c)
  -> LedgerView (TPraos c)
  -> SL.KeyHash 'SL.StakePool c
  -> CertifiedVRF (VRF c) SL.Seed
  -> Bool
meetsLeaderThreshold
  TPraosConfig { tpraosParams }
  SL.LedgerView { lvPoolDistr }
  keyHash
  certNat
    = SL.checkVRFValue
        (VRF.certifiedNatural certNat)
        r
        (tpraosLeaderF tpraosParams)
  where
    SL.PoolDistr poolDistr = lvPoolDistr
    r = maybe 0 fst
        $ Map.lookup keyHash poolDistr

{-------------------------------------------------------------------------------
  Condense
-------------------------------------------------------------------------------}

instance (Condense toSign, TPraosCrypto c)
  => Condense (TPraosFields c toSign) where
  -- TODO Nicer 'Condense' instance
  condense = condense . tpraosToSign
