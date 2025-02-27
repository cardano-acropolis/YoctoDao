{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE LambdaCase          #-}

module Yocto (
  Voting (..)
  , VotingDatum (..)
  , VotingRedeemer (..)
  , votingPassValidator
  , votingPassValidatorInstance
  , votingPassValidatorHash
  , votingPassValidatorScript
  , votingPassScriptAddress
  , curSymbol
  , policy
  , mkPolicy
             ) where

import           Control.Monad          hiding (fmap)
import qualified Data.Map               as Map
import           Data.Text              (Text)
import           Data.Void              (Void)
import           Plutus.Contract        as Contract
import qualified PlutusTx
import           PlutusTx.IsData
import           PlutusTx.Prelude       hiding (Semigroup(..), unless)
import           Ledger                 hiding (singleton)
import           Ledger.Constraints     as Constraints
import qualified Ledger.Typed.Scripts   as Scripts
import qualified Ledger.Contexts                   as Validation
import           Ledger.Value           as Value
import           Playground.Contract    (printJson, printSchemas, ensureKnownCurrencies, stage, ToSchema, NonEmpty(..) )
import           Playground.TH          (mkKnownCurrencies, mkSchemaDefinitions, ensureKnownCurrencies)
import           Playground.Types       (KnownCurrency (..))
import           Prelude                (Semigroup (..))
import           Text.Printf            (printf)
import           GHC.Generics           (Generic)
import           Data.String            (IsString (..))
import           Data.Aeson             (ToJSON, FromJSON)
import           Playground.Contract

newtype VotingDatum = VotingDatum BuiltinData deriving newtype (PlutusTx.ToData, PlutusTx.FromData, PlutusTx.UnsafeFromData)
PlutusTx.makeLift ''VotingDatum

-- Need to specify exactly how the voting will be performed. However,
-- the BuiltinData type is probably flexible enough for now.
newtype VotingRedeemer = VotingRedeemer BuiltinData deriving newtype (PlutusTx.ToData, PlutusTx.FromData, PlutusTx.UnsafeFromData)
PlutusTx.makeLift ''VotingRedeemer

type DAOSchema =
        Endpoint     "newGrant" GrantFundParams -- Set up new fund
        .\/ Endpoint "fund"     FundParams      -- Fund contract
        .\/ Endpoint "vote"     VoteParams      -- Vote for recipient
        .\/ Endpoint "disburse" DisburseParams  -- Sends funds to
        -- recipinent and implies consent to contract terms else
        -- allows for the return of all funds to donors after deadline
        .\/ Endpoint "update"   UpdateParams    -- Burns old tokens and
        -- updates DAO

{-# INLINABLE votingPassValidator #-}
votingPassValidator :: AssetClass -> VotingDatum -> VotingRedeemer -> ScriptContext -> Bool
votingPassValidator asset vd vr ctx =
  let
      txInfo = scriptContextTxInfo ctx
      -- We map over all of the inputs to the transaction to gather
      -- the number of votes present.
      txInValues = [txOutValue $ txInInfoResolved txIn | txIn <- txInfoInputs $ scriptContextTxInfo ctx]
      tokenValues = [assetClassValueOf val asset | val <- txInValues]
      votes = sum tokenValues -- sum the occurrences of the tokenClass inside of txInValues
  in
      traceIfFalse "Not enough votes" (votes > 5)

-- We need this because we are returning a Boolean above.
data Voting
instance Scripts.ValidatorTypes Voting where
    type instance DatumType Voting = VotingDatum
    type instance RedeemerType Voting = VotingRedeemer


-- This section allows for the code above to be easily compiled to the information necessary to deploy on chain.
votingPassValidatorInstance :: AssetClass -> Scripts.TypedValidator Voting
votingPassValidatorInstance asset = Scripts.mkTypedValidator @Voting
    ($$(PlutusTx.compile [||  votingPassValidator ||])
    `PlutusTx.applyCode`
    PlutusTx.liftCode asset)
    $$(PlutusTx.compile [|| wrap ||]) where
        wrap = Scripts.wrapValidator @VotingDatum @VotingRedeemer

votingPassValidatorHash :: AssetClass -> ValidatorHash
votingPassValidatorHash = Scripts.validatorHash . votingPassValidatorInstance

votingPassValidatorScript :: AssetClass -> Validator
votingPassValidatorScript = Scripts.validatorScript . votingPassValidatorInstance

votingPassScriptAddress :: AssetClass -> Address
votingPassScriptAddress = Ledger.scriptAddress . votingPassValidatorScript

-- This section manages the Governance Token. Should this section
-- change a reissuance of gov tokens is required.
{-# INLINABLE mkPolicy #-}
mkPolicy :: AssetClass -> BuiltinData -> ScriptContext -> Bool
mkPolicy asset _ ctx = traceIfFalse "The DAO's NFT is not present." (nftSum > 0)
  where
    txInfo = scriptContextTxInfo ctx
    txInValues = [txOutValue $ txInInfoResolved txIn | txIn <- txInfoInputs $ scriptContextTxInfo ctx]
    nftValues = [assetClassValueOf val asset | val <- txInValues]
    nftSum = sum nftValues

policy :: AssetClass -> Scripts.MintingPolicy
policy asset = mkMintingPolicyScript $
    $$(PlutusTx.compile [|| Scripts.wrapMintingPolicy . mkPolicy ||])
    `PlutusTx.applyCode`
    PlutusTx.liftCode asset

curSymbol :: AssetClass -> CurrencySymbol
curSymbol asset = scriptCurrencySymbol $ policy asset

data GrantFundParams = GrantFundParams
  { ammountInFund :: Value
  , idOfFund :: ByteString
  }
  deriving stock (Haskell.Eq, Haskell.Show, Generic)
  deriving anyclass (FromJSON, ToJSON, ToSchema, ToArgument)

data FundParams = FundParams
  { ammountToFund :: Value
  , idOfFund :: ByteString
  }
  deriving stock (Haskell.Eq, Haskell.Show, Generic)
  deriving anyclass (FromJSON, ToJSON, ToSchema, ToArgument)

data VoteParams = VoteParams
  { ammountInFund :: Value
  , idOfFund :: ByteString
  }
  deriving stock (Haskell.Eq, Haskell.Show, Generic)
  deriving anyclass (FromJSON, ToJSON, ToSchema, ToArgument)

newGrantFund :: AsContractError e => Promise () DAOSchema e ()
newGrantFund = endpoint @"newGrantFund" @GrantFundParams $ \(GrantFundParams amt id) -> do
    logInfo @Haskell.String $ "Create new grant " <> Haskell.show id <> " for " <> Haskell.show amt <> " ada"
    let tx         = Constraints.mustPayToTheScript 
    void (submitTxConstraints gameInstance tx)

fund :: AsContractError e => Promise () DAOSchema e ()
fund = endpoint @"fund" @FundParams $ \(FundParams amt id) -> do
    logInfo @Haskell.String $ "Pay " <> Haskell.show amt <> " to the the grant fund"
    let tx         = Constraints.mustPayToTheScript amt
    void (submitTxConstraints gameInstance tx)
