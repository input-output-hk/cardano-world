{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Ouroboros.Consensus.HardFork.Combinator.Info (
    -- * Era info
    SingleEraInfo(..)
  , LedgerEraInfo(..)
  ) where

import           Codec.Serialise (Serialise)
import           Data.Text (Text)
import           GHC.Generics (Generic)

import           Cardano.Prelude (NoUnexpectedThunks (..))

{-------------------------------------------------------------------------------
  Era info
-------------------------------------------------------------------------------}

-- | Information about an era (mostly for type errors)
data SingleEraInfo blk = SingleEraInfo {
      singleEraName :: !Text
    }
  deriving stock    (Generic, Eq, Show)
  deriving anyclass (NoUnexpectedThunks, Serialise)

-- | Additional newtype wrapper around 'SingleEraInfo'
--
-- This is primarily useful for use in error messages: it marks which era
-- info came from the ledger, and which came from a tx/block/header/etc.
newtype LedgerEraInfo blk = LedgerEraInfo {
      getLedgerEraInfo :: SingleEraInfo blk
    }
  deriving stock   (Eq, Show)
  deriving newtype (NoUnexpectedThunks, Serialise)
