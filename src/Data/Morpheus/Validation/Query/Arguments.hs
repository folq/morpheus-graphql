{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections  #-}

module Data.Morpheus.Validation.Query.Arguments
  ( validateArguments
  ) where

import           Data.Morpheus.Error.Arguments                 (argumentGotInvalidValue, argumentNameCollision,
                                                                undefinedArgument, unknownArguments)
import           Data.Morpheus.Error.Input                     (InputValidation, inputErrorMessage)
import           Data.Morpheus.Error.Internal                  (internalUnknownTypeMessage)
import           Data.Morpheus.Error.Variable                  (incompatibleVariableType, undefinedVariable)
import           Data.Morpheus.Rendering.RenderGQL             (RenderGQL (..))
import           Data.Morpheus.Types.Internal.AST.Operation    (ValidVariables, Variable (..))
import           Data.Morpheus.Types.Internal.AST.RawSelection (RawArgument (..), RawArguments, Reference (..))
import           Data.Morpheus.Types.Internal.AST.Selection    (Argument (..), ArgumentOrigin (..), Arguments)
import           Data.Morpheus.Types.Internal.Base             (EnhancedKey (..), Position)
import           Data.Morpheus.Types.Internal.Data             (DataArgument, DataField (..), DataField, DataTypeLib,
                                                                TypeAlias (..), isFieldNullable, isWeaker)
import           Data.Morpheus.Types.Internal.Validation       (Validation)
import           Data.Morpheus.Types.Internal.Value            (Value (Null))
import           Data.Morpheus.Validation.Internal.Utils       (checkForUnknownKeys, checkNameCollision, getInputType)
import           Data.Morpheus.Validation.Internal.Value       (validateInputValue)
import           Data.Text                                     (Text)

resolveArgumentVariables :: Text -> ValidVariables -> DataField -> RawArguments -> Validation Arguments
resolveArgumentVariables operatorName variables DataField {fieldName, fieldArgs} = mapM resolveVariable
  where
    resolveVariable :: (Text, RawArgument) -> Validation (Text, Argument)
    resolveVariable (key, RawArgument argument) = pure (key, argument)
    resolveVariable (key, VariableReference Reference {referenceName, referencePosition}) =
      (key, ) . toArgument <$> lookupVar
      where
        toArgument argumentValue =
          Argument {argumentValue, argumentOrigin = VARIABLE, argumentPosition = referencePosition}
        lookupVar =
          case lookup referenceName variables of
            Nothing -> Left $ undefinedVariable operatorName referencePosition referenceName
            Just Variable {variableValue, variableType, variableTypeWrappers} ->
              case lookup key fieldArgs of
                Nothing -> Left $ unknownArguments fieldName [EnhancedKey key referencePosition]
                Just DataField {fieldType = fieldT@TypeAlias {aliasTyCon, aliasWrappers}} ->
                  if variableType == aliasTyCon && not (isWeaker variableTypeWrappers aliasWrappers)
                    then return variableValue
                    else Left $ incompatibleVariableType referenceName varSignature fieldSignature referencePosition
                  where varSignature = renderWrapped variableType variableTypeWrappers
                        fieldSignature = render fieldT

validateArgument :: DataTypeLib -> Position -> Arguments -> (Text, DataArgument) -> Validation (Text, Argument)
validateArgument lib fieldPosition requestArgs (key, argType@DataField {fieldType = TypeAlias { aliasTyCon
                                                                                              , aliasWrappers
                                                                                              }}) =
  case lookup key requestArgs of
    Nothing                                            -> handleNullable
    Just argument@Argument {argumentOrigin = VARIABLE} -> pure (key, argument) -- Variables are already checked in Variable Validation
    Just Argument {argumentValue = Null}               -> handleNullable
    Just argument                                      -> validateArgumentValue argument
  where
    handleNullable
      | isFieldNullable argType =
        pure (key, Argument {argumentValue = Null, argumentOrigin = INLINE, argumentPosition = fieldPosition})
      | otherwise = Left $ undefinedArgument (EnhancedKey key fieldPosition)
    -------------------------------------------------------------------------
    validateArgumentValue :: Argument -> Validation (Text, Argument)
    validateArgumentValue arg@Argument {argumentValue, argumentPosition} =
      getInputType aliasTyCon lib (internalUnknownTypeMessage aliasTyCon) >>= checkType >> pure (key, arg)
      where
        checkType type' = handleInputError (validateInputValue lib [] aliasWrappers type' (key, argumentValue))
        ---------
        handleInputError :: InputValidation a -> Validation ()
        handleInputError (Left err) = Left $ argumentGotInvalidValue key (inputErrorMessage err) argumentPosition
        handleInputError _          = pure ()

validateArguments ::
     DataTypeLib -> Text -> ValidVariables -> (Text, DataField) -> Position -> RawArguments -> Validation Arguments
validateArguments typeLib operatorName variables (key, field@DataField {fieldArgs}) pos rawArgs = do
  args <- resolveArgumentVariables operatorName variables field rawArgs
  dataArgs <- checkForUnknownArguments args
  mapM (validateArgument typeLib pos args) dataArgs
  where
    checkForUnknownArguments :: Arguments -> Validation [(Text, DataField)]
    checkForUnknownArguments args =
      checkForUnknownKeys enhancedKeys fieldKeys argError >> checkNameCollision enhancedKeys argumentNameCollision >>
      pure fieldArgs
      where
        argError = unknownArguments key
        enhancedKeys = map argToKey args
        argToKey (key', Argument {argumentPosition}) = EnhancedKey key' argumentPosition
        fieldKeys = map fst fieldArgs
