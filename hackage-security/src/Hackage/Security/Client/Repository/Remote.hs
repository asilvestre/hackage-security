-- | An implementation of Repository that talks to repositories over HTTP.
--
-- This implementation is itself parameterized over a 'HttpClient', so that it
-- it not tied to a specific library; for instance, 'HttpClient' can be
-- implemented with the @HTTP@ library, the @http-client@ libary, or others.
--
-- It would also be possible to give _other_ Repository implementations that
-- talk to repositories over HTTP, if you want to make other design decisions
-- than we did here, in particular:
--
-- * We attempt to do incremental downloads of the index when possible.
-- * We reuse the "Repository.Local"  to deal with the local cache.
-- * We download @timestamp.json@ and @snapshot.json@ together. This is
--   implemented here because:
--   - One level down (HttpClient) we have no access to the local cache
--   - One level up (Repository API) would require _all_ Repositories to
--     implement this optimization.
module Hackage.Security.Client.Repository.Remote (
    -- * Server capabilities
    ServerCapabilities -- opaque
  , newServerCapabilities
  , getServerSupportsAcceptBytes
  , setServerSupportsAcceptBytes
    -- * Abstracting over HTTP libraries
  , BodyReader
  , DownloadedRange(..)
  , HttpClient(..)
  , HttpOption(..)
  , FileSize(..)
    -- ** Utility
  , fileSizeWithinBounds
    -- * Top-level API
  , withRepository
  ) where

import Control.Concurrent
import Control.Exception
import Control.Monad.Except
import Network.URI hiding (uriPath, path)
import System.IO
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BS.L

import Hackage.Security.Client.Formats
import Hackage.Security.Client.Repository
import Hackage.Security.Client.Repository.Cache (Cache)
import Hackage.Security.Trusted
import Hackage.Security.TUF
import Hackage.Security.Util.IO
import Hackage.Security.Util.Path
import Hackage.Security.Util.Some
import qualified Hackage.Security.Client.Repository.Cache as Cache

{-------------------------------------------------------------------------------
  Server capabilities
-------------------------------------------------------------------------------}

-- | Server capabilities
--
-- As the library interacts with the server and receives replies, we may
-- discover more information about the server's capabilities; for instance,
-- we may discover that it supports incremental downloads.
newtype ServerCapabilities = SC (MVar ServerCapabilities_)

-- | Internal type recording the various server capabilities we support
--
-- This is not exported; we only export functions that work on
-- 'ServerCapabilities'.
data ServerCapabilities_ = ServerCapabilities {
      serverSupportsAcceptBytes :: Bool
    }

newServerCapabilities :: IO ServerCapabilities
newServerCapabilities = SC <$> newMVar ServerCapabilities {
      serverSupportsAcceptBytes = False
    }

setServerSupportsAcceptBytes :: ServerCapabilities -> Bool -> IO ()
setServerSupportsAcceptBytes (SC mv) x = modifyMVar_ mv $ \caps ->
    return $ caps { serverSupportsAcceptBytes = x }

getServerSupportsAcceptBytes :: ServerCapabilities -> IO Bool
getServerSupportsAcceptBytes (SC mv) = withMVar mv $ \caps ->
    return $ serverSupportsAcceptBytes caps

{-------------------------------------------------------------------------------
  Abstraction over HTTP clients (such as HTTP, http-conduit, etc.)
-------------------------------------------------------------------------------}

data FileSize =
    -- | For most files we download we know the exact size beforehand
    -- (because this information comes from the snapshot or delegated info)
    FileSizeExact Int

    -- | For some files we might not know the size beforehand, but we might
    -- be able to provide an upper bound (timestamp, root info)
  | FileSizeBound Int

    -- | If we don't want to guess, we can also just indicate we have no idea
    -- what size file we are expecting. This means we cannot protect against
    -- endless data attacks however.
    --
    -- TODO: Once we put in estimates we should get rid of this.
  | FileSizeUnknown

fileSizeWithinBounds :: Int -> FileSize -> Bool
fileSizeWithinBounds sz (FileSizeExact sz') = sz <= sz'
fileSizeWithinBounds sz (FileSizeBound sz') = sz <= sz'
fileSizeWithinBounds _  FileSizeUnknown     = True

data DownloadedRange = DownloadedRange | DownloadedEntireFile

-- | Abstraction over HTTP clients
--
-- This avoids insisting on a particular implementation (such as the HTTP
-- package) and allows for other implementations (such as a conduit based one)
data HttpClient = HttpClient {
    -- | Download a file
    httpClientGet :: forall a.
                     [HttpOption]
                  -> URI
                  -> (BodyReader -> IO a)
                  -> IO a

    -- | Download a byte range
    --
    -- Range is starting and (exclusive) end offset in bytes.
    --
    -- Servers can respond to a range request by sending the entire file
    -- instead. We tell the callback if it got the range of the entire file.
  , httpClientGetRange :: forall a.
                          [HttpOption]
                       -> URI
                       -> (Int, Int)
                       -> (DownloadedRange -> BodyReader -> IO a)
                       -> IO a

    -- | Server capabilities
    --
    -- HTTP clients should use 'newServerCapabilities' on initialization.
  , httpClientCapabilities :: ServerCapabilities

    -- | Catch any custom exceptions thrown and wrap them as 'CustomException's
  , httpWrapCustomEx :: forall a. IO a -> IO a
  }

-- | Additional options for HTTP downloads
--
-- Since different libraries represent headers differently, here we just
-- abstract over the few headers that we might want to set
data HttpOption =
    -- | Set @Cache-Control: max-age=0@
    HttpOptionMaxAge0

    -- | Set @Cache-Control: no-transform@
  | HttpOptionNoTransform

{-------------------------------------------------------------------------------
  Top-level API
-------------------------------------------------------------------------------}

-- | Initialize the repository (and cleanup resources afterwards)
--
-- We allow to specify multiple mirrors to initialize the repository. These
-- are mirrors that can be found "out of band" (out of the scope of the TUF
-- protocol), for example in a @cabal.config@ file. The TUF protocol itself
-- will specify that any of these mirrors can serve a @mirrors.json@ file
-- that itself contains mirrors; we consider these as _additional_ mirrors
-- to the ones that are passed here.
--
-- NOTE: The list of mirrors should be non-empty (and should typically include
-- the primary server).
--
-- TODO: In the future we could allow finer control over precisely which
-- mirrors we use (which combination of the mirrors that are passed as arguments
-- here and the mirrors that we get from @mirrors.json@) as well as indicating
-- mirror preferences.
withRepository
  :: HttpClient            -- ^ Implementation of the HTTP protocol
  -> [URI]                 -- ^ "Out of band" list of mirrors
  -> Cache                 -- ^ Location of local cache
  -> RepoLayout            -- ^ Repository layout
  -> (LogMessage -> IO ()) -- ^ Logger
  -> (Repository -> IO a)  -- ^ Callback
  -> IO a
withRepository http outOfBandMirrors cache repLayout logger callback = do
    selectedMirror <- newMVar Nothing
    callback Repository {
        repWithRemote    = fileLast $ withRemote repLayout http selectedMirror cache logger
      , repGetCached     = Cache.getCached     cache
      , repGetCachedRoot = Cache.getCachedRoot cache
      , repClearCache    = Cache.clearCache    cache
      , repGetFromIndex  = Cache.getFromIndex  cache (repoIndexLayout repLayout)
      , repWithMirror    = withMirror http selectedMirror logger outOfBandMirrors
      , repLog           = logger
      , repLayout        = repLayout
      , repDescription   = "Remote repository at " ++ show outOfBandMirrors
      }
  where
    fileLast f = flip . f

{-------------------------------------------------------------------------------
  Implementations of the various methods of Repository
-------------------------------------------------------------------------------}

-- | We select a mirror in 'withMirror' (the implementation of 'repWithMirror').
-- Outside the scope of 'withMirror' no mirror is selected, and a call to
-- 'withRemote' will throw an exception. If this exception is ever thrown its
-- a bug: calls to 'withRemote' ('repWithRemote') should _always_ be in the
-- scope of 'repWithMirror'.
type SelectedMirror = MVar (Maybe URI)

-- | Get a file from the server
withRemote :: forall fs a.
              RepoLayout -> HttpClient -> SelectedMirror -> Cache
           -> (LogMessage -> IO ())
           -> IsRetry
           -> (SelectedFormat fs -> TempPath -> IO a)
           -> RemoteFile fs
           -> IO a
withRemote repoLayout httpClient selectedMirror cache logger isRetry callback = \remoteFile -> do
   -- NOTE: Cannot use withMVar here, because the callback would be inside
   -- the scope of the withMVar, and there might be further calls to
   -- withRemote made by this callback, leading to deadlock.
   mBaseURI <- readMVar selectedMirror
   case mBaseURI of
     Nothing ->
       throwIO $ userError "Internal error: no mirror selected"
     Just baseURI -> do
       let config = RemoteConfig {
                        cfgLayout = repoLayout
                      , cfgClient = httpClient
                      , cfgBase   = baseURI
                      , cfgCache  = cache
                      }

       -- Figure out if we should do an incremental download
       mIncremental <- shouldDoIncremental config remoteFile

       -- If so, attempt it. However, if this throws an I/O exception or a
       -- verification error we try again using a full download
       didDownload <- case mIncremental of
         Left Nothing ->
           return Nothing
         Left (Just failure) -> do
           logger $ LogUpdateFailed (describeRemoteFile remoteFile) failure
           return Nothing
         Right (sf, len, fp) -> do
           logger $ LogUpdating (describeRemoteFile remoteFile)
           let wrapCustomEx = httpWrapCustomEx httpClient
               incr = incTar config httpOpts len fp $ callback sf
           catchRecoverable wrapCustomEx (Just <$> incr) $ \ex -> do
             let failure = UpdateFailed ex
             logger $ LogUpdateFailed (describeRemoteFile remoteFile) failure
             return Nothing

       case didDownload of
         Just did -> return did
         Nothing  -> do
           logger $ LogDownloading (describeRemoteFile remoteFile)
           getFile config httpOpts remoteFile callback
  where
    httpOpts :: [HttpOption]
    httpOpts = httpOptions isRetry

-- | HTTP options
--
-- We want to make sure caches don't transform files in any way (as this will
-- mess things up with respect to hashes etc). Additionally, after a validation
-- error we want to make sure caches get files upstream in case the validation
-- error was because the cache updated files out of order.
httpOptions :: IsRetry -> [HttpOption]
httpOptions FirstAttempt         = [HttpOptionNoTransform]
httpOptions AfterValidationError = [HttpOptionNoTransform, HttpOptionMaxAge0]

-- | Should we do an incremental update?
--
-- Returns either 'Left' the reason why we cannot do an incremental update (or
-- @Nothing@ if we simply never update this kind of file), or else 'Right' the
-- name of the local file that we should update.
shouldDoIncremental
  :: forall fs.
     RemoteConfig   -- ^ Internal configuration
  -> RemoteFile fs  -- ^ File we need to download
  -> IO (Either (Maybe UpdateFailure)
                (SelectedFormat fs, Trusted FileLength, AbsolutePath))
shouldDoIncremental RemoteConfig{..} remoteFile = runExceptT $ do
    -- Currently the only file which we download incrementally is the index
    formats :: Formats fs (Trusted FileLength) <-
      case remoteFile of
        RemoteIndex _ lens -> return lens
        _ -> throwError Nothing

    -- The server must be able to provide the index in uncompressed form
    -- NOTE: The two @SZ Fun@ expressions here have different types.
    (selected :: SelectedFormat fs, len :: Trusted FileLength) <-
      case formats of
        FsUn   lenUn   -> return (SZ FUn, lenUn)
        FsUnGz lenUn _ -> return (SZ FUn, lenUn)
        _ -> throwError $ Just UpdateImpossibleOnlyCompressed

    -- Server must support @Range@ with a byte-range
    supportsAcceptBytes <- lift $ getServerSupportsAcceptBytes httpClientCapabilities
    unless supportsAcceptBytes $
      throwError $ Just UpdateImpossibleUnsupported

    -- We already have a local file to be updated
    -- (if not we should try to download the initial file in compressed form)
    cachedIndex <- do
      mCachedIndex <- lift $ Cache.getCachedIndex cfgCache
      case mCachedIndex of
        Nothing -> throwError $ Just UpdateImpossibleNoLocalCopy
        Just fp -> return fp

    -- TODO: Other factors to decide whether or not we want to do incremental updates
    -- TODO: (Not here:) deal with transparent compression of the update
    -- (but see <https://github.com/haskell/cabal/issues/678> and
    -- @Distribution.Client.GZipUtils@ in @cabal-install@)

    return (selected, len, cachedIndex)
  where
    HttpClient{..} = cfgClient

-- | Get any file from the server, without using incremental updates
getFile :: RemoteConfig   -- ^ Internal configuration
        -> [HttpOption]   -- ^ Additional HTTP optons
        -> RemoteFile fs  -- ^ File to download
        -> (SelectedFormat fs -> TempPath -> IO a) -- ^ Callback after download
        -> IO a
getFile RemoteConfig{..} httpOpts remoteFile callback =
    withSystemTempFile (takeFileName (uriPath uri)) $ \tempPath h -> do
      -- We are careful NOT to scope the remainder of the computation underneath
      -- the httpClientGet
      httpClientGet httpOpts uri $ execBodyReader description sz h
      hClose h
      result <- callback format tempPath
      Cache.cacheRemoteFile cfgCache
                            tempPath
                            (selectedFormatSome format)
                            (mustCache remoteFile)
      return result
  where
    description = describeRemoteFile remoteFile
    (format, (uri, sz)) = formatsPrefer
                            (remoteFileNonEmpty remoteFile)
                            FGz
                            (formatsZip
                              (remoteFileURI cfgLayout cfgBase remoteFile)
                              (remoteFileSize remoteFile))

    HttpClient{..} = cfgClient

-- | Get a tar file incrementally
--
-- Sadly, this has some tar-specific functionality
incTar :: RemoteConfig        -- ^ Internal configuration
       -> [HttpOption]        -- ^ Additional HTTP options
       -> Trusted FileLength  -- ^ Expected length
       -> AbsolutePath        -- ^ Location of cached tar (after callback)
       -> (TempPath -> IO a)  -- ^ Callback on the updated tar
       -> IO a
incTar RemoteConfig{..} httpOpts len cachedFile callback = do
    -- TODO: Once we have a local tarball index, this is not necessary
    currentSize <- getFileSize cachedFile
    let currentMinusTrailer = currentSize - 1024
        fileSz  = fileLength (trusted len)
        range   = (fromInteger currentMinusTrailer, fileSz)
        rangeSz = FileSizeExact (snd range - fst range)
        totalSz = FileSizeExact fileSz
    withSystemTempFile (takeFileName (uriPath uri)) $ \tempPath h -> do
      BS.L.hPut h =<< readLazyByteString cachedFile
      hSeek h AbsoluteSeek currentMinusTrailer
      -- As in 'getFile', make sure we don't scope the remainder of the
      -- computation underneath the httpClientGetRange
      httpClientGetRange httpOpts uri range $ \downloadedRange br -> do
        case downloadedRange of
          DownloadedRange ->
            execBodyReader "index" rangeSz h br
          DownloadedEntireFile -> do
            -- If we downloaded the entire file we wasted some work here. The
            -- alternative is to only copy in the file once we know for sure
            -- that we did get the range we requested, but this would require
            -- keeping the connection to the server open for longer. Not sure
            -- what the best tradeoff is here. Either way, this should be rare.
            hSeek h AbsoluteSeek 0
            execBodyReader "index" totalSz h br
      hClose h
      result <- callback tempPath
      Cache.cacheRemoteFile cfgCache tempPath (Some FUn) CacheIndex
      return result
  where
    uri = modifyUriPath cfgBase (`anchorRepoPathRemotely` repoLayoutIndexTar)

    RepoLayout{..} = cfgLayout
    HttpClient{..} = cfgClient

-- | Mirror selection
withMirror :: forall a.
              HttpClient             -- ^ HTTP client
           -> SelectedMirror         -- ^ MVar indicating currently mirror
           -> (LogMessage -> IO ())  -- ^ Logger
           -> [URI]                  -- ^ Out-of-band mirrors
           -> Maybe [Mirror]         -- ^ TUF mirrors
           -> IO a                   -- ^ Callback
           -> IO a
withMirror HttpClient{..} selectedMirror logger oobMirrors tufMirrors callback =
    -- TODO: We will want to make the construction of this list configurable.
    go $ oobMirrors ++ maybe [] (map mirrorUrlBase) tufMirrors
  where
    go :: [URI] -> IO a
    -- Empty list of mirrors is a bug
    go [] = throwIO $ userError "No mirrors configured"
    -- If we only have a single mirror left, let exceptions be thrown up
    go [m] = do
      logger $ LogSelectedMirror (show m)
      select m $ callback
    -- Otherwise, catch exceptions and if any were thrown, try with different
    -- mirror
    go (m:ms) = do
      logger $ LogSelectedMirror (show m)
      catchRecoverable httpWrapCustomEx (select m callback) $ \ex -> do
        logger $ LogMirrorFailed (show m) ex
        go ms

    select :: URI -> IO a -> IO a
    select uri =
      bracket_ (modifyMVar_ selectedMirror $ \_ -> return $ Just uri)
               (modifyMVar_ selectedMirror $ \_ -> return Nothing)

{-------------------------------------------------------------------------------
  Body readers
-------------------------------------------------------------------------------}

-- | An @IO@ action that represents an incoming response body coming from the
-- server.
--
-- The action gets a single chunk of data from the response body, or an empty
-- bytestring if no more data is available.
--
-- This definition is copied from the @http-client@ package.
type BodyReader = IO BS.ByteString

-- | Execute a body reader
--
-- NOTE: This intentially does NOT use the @with..@ pattern: we want to execute
-- the entire body reader (or cancel it) and write the results to a file and
-- then continue. We do NOT want to scope the remainder of the computation
-- as part of the same HTTP request.
--
-- TODO: Deal with minimum download rate.
execBodyReader :: String      -- ^ Description of the file (for error msgs only)
               -> FileSize    -- ^ Maximum file size
               -> Handle      -- ^ Handle to write data too
               -> BodyReader  -- ^ The action to give us blocks from the file
               -> IO ()
execBodyReader file mlen h br = go 0
  where
    go :: Int -> IO ()
    go sz = do
      unless (sz `fileSizeWithinBounds` mlen) $
        throwIO $ VerificationErrorFileTooLarge file
      bs <- br
      if BS.null bs
        then return ()
        else BS.hPut h bs >> go (sz + BS.length bs)

{-------------------------------------------------------------------------------
  Information about remote files
-------------------------------------------------------------------------------}

remoteFileURI :: RepoLayout -> URI -> RemoteFile fs -> Formats fs URI
remoteFileURI repoLayout baseURI = fmap aux . remoteFilePath repoLayout
  where
    aux :: RepoPath -> URI
    aux repoPath = modifyUriPath baseURI (`anchorRepoPathRemotely` repoPath)

-- | Extracting or estimating file sizes
--
-- TODO: Put in estimates
remoteFileSize :: RemoteFile fs -> Formats fs FileSize
remoteFileSize (RemoteTimestamp) =
    FsUn FileSizeUnknown
remoteFileSize (RemoteRoot mLen) =
    FsUn $ maybe FileSizeUnknown (FileSizeExact . fileLength . trusted) mLen
remoteFileSize (RemoteSnapshot len) =
    FsUn $ FileSizeExact (fileLength (trusted len))
remoteFileSize (RemoteMirrors len) =
    FsUn $ FileSizeExact (fileLength (trusted len))
remoteFileSize (RemoteIndex _ lens) =
    fmap (FileSizeExact . fileLength . trusted) lens
remoteFileSize (RemotePkgTarGz _pkgId len) =
    FsGz $ FileSizeExact (fileLength (trusted len))

{-------------------------------------------------------------------------------
  Configuration
-------------------------------------------------------------------------------}

-- | Remote repository configuration
--
-- This is purely for internal convenience.
data RemoteConfig = RemoteConfig {
      cfgLayout :: RepoLayout
    , cfgClient :: HttpClient
    , cfgBase   :: URI
    , cfgCache  :: Cache
    }