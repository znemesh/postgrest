{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TypeSynonymInstances #-}

module PostgREST.Error (pgErrResponse, errResponse) where

import           Protolude
import           Data.Aeson                ((.=))
import qualified Data.Aeson                as JSON
import qualified Data.Text                 as T
import qualified Hasql.Pool                as P
import qualified Hasql.Session             as H
import           Network.HTTP.Types.Header
import qualified Network.HTTP.Types.Status as HT
import           Network.Wai               (Response, responseLBS)

errResponse :: HT.Status -> Text -> Response
errResponse status message = responseLBS status [(hContentType, "application/json")] (toS $ T.concat ["{\"message\":\"",message,"\"}"])

pgErrResponse :: Bool -> P.UsageError -> Response
pgErrResponse authed e =
  let status = httpStatus authed e
      jsonType = (hContentType, "application/json")
      wwwAuth = ("WWW-Authenticate", "Bearer")
      hdrs = if status == HT.status401
                then [jsonType, wwwAuth]
                else [jsonType] in
  responseLBS status hdrs (JSON.encode e)

instance JSON.ToJSON P.UsageError where
  toJSON (P.ConnectionError e) = JSON.object [
    "code" .= ("" :: T.Text),
    "message" .= ("Connection error" :: T.Text),
    "details" .= (toS $ fromMaybe "" e :: T.Text)]
  toJSON (P.SessionError e) = JSON.toJSON e -- H.Error

instance JSON.ToJSON H.Error where
  toJSON (H.ResultError (H.ServerError c m d h)) = JSON.object [
    "code" .= (toS c::T.Text),
    "message" .= (toS m::T.Text),
    "details" .= (fmap toS d::Maybe T.Text),
    "hint" .= (fmap toS h::Maybe T.Text)]
  toJSON (H.ResultError (H.UnexpectedResult m)) = JSON.object [
    "message" .= (m::T.Text)]
  toJSON (H.ResultError (H.RowError i H.EndOfInput)) = JSON.object [
    "message" .= ("Row error: end of input"::T.Text),
    "details" .=
      ("Attempt to parse more columns than there are in the result"::Text),
    "details" .= (("Row number " <> show i)::Text)]
  toJSON (H.ResultError (H.RowError i H.UnexpectedNull)) = JSON.object [
    "message" .= ("Row error: unexpected null"::Text),
    "details" .= ("Attempt to parse a NULL as some value."::Text),
    "details" .= (("Row number " <> show i)::Text)]
  toJSON (H.ResultError (H.RowError i (H.ValueError d))) = JSON.object [
    "message" .= ("Row error: Wrong value parser used"::Text),
    "details" .= d,
    "details" .= (("Row number " <> show i)::Text)]
  toJSON (H.ResultError (H.UnexpectedAmountOfRows i)) = JSON.object [
    "message" .= ("Unexpected amount of rows"::Text),
    "details" .= i]
  toJSON (H.ClientError d) = JSON.object [
    "message" .= ("Database client error"::Text),
    "details" .= (fmap toS d::Maybe T.Text)]

httpStatus :: Bool -> P.UsageError -> HT.Status
httpStatus _ (P.ConnectionError _) = HT.status500
httpStatus authed (P.SessionError (H.ResultError (H.ServerError c _ _ _))) =
  case toS c of
    '0':'8':_ -> HT.status503 -- pg connection err
    '0':'9':_ -> HT.status500 -- triggered action exception
    '0':'L':_ -> HT.status403 -- invalid grantor
    '0':'P':_ -> HT.status403 -- invalid role specification
    "23503"   -> HT.status409 -- foreign_key_violation
    "23505"   -> HT.status409 -- unique_violation
    '2':'5':_ -> HT.status500 -- invalid tx state
    '2':'8':_ -> HT.status403 -- invalid auth specification
    '2':'D':_ -> HT.status500 -- invalid tx termination
    '3':'8':_ -> HT.status500 -- external routine exception
    '3':'9':_ -> HT.status500 -- external routine invocation
    '3':'B':_ -> HT.status500 -- savepoint exception
    '4':'0':_ -> HT.status500 -- tx rollback
    '5':'3':_ -> HT.status503 -- insufficient resources
    '5':'4':_ -> HT.status413 -- too complex
    '5':'5':_ -> HT.status500 -- obj not on prereq state
    '5':'7':_ -> HT.status500 -- operator intervention
    '5':'8':_ -> HT.status500 -- system error
    'F':'0':_ -> HT.status500 -- conf file error
    'H':'V':_ -> HT.status500 -- foreign data wrapper error
    'P':'0':_ -> HT.status500 -- PL/pgSQL Error
    'X':'X':_ -> HT.status500 -- internal Error
    "42P01"   -> HT.status404 -- undefined table
    "42501"   -> if authed then HT.status403 else HT.status401 -- insufficient privilege
    _         -> HT.status400
httpStatus _ (P.SessionError (H.ResultError _)) = HT.status500
httpStatus _ (P.SessionError (H.ClientError _)) = HT.status503
