{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.Wai.Shake.Ghcjs (
  serveGhcjs,
  BuildConfig(..),
  Exec(..),
  Environment(..),
  mkDevelopmentApp,

  -- exported for testing:
  createJsToConsole,
  findMainFile,
 ) where

import           Control.Concurrent
import           Control.Exception
import           Control.Monad
import qualified Data.ByteString.Lazy as LBS
import           Data.CaseInsensitive (mk)
import           Data.Default ()
import           Data.String.Conversions
import           Data.String.Interpolate
import           Data.String.Interpolate.Util
import           Development.Shake as Shake
import           Language.ECMAScript3.PrettyPrint
import           Language.ECMAScript3.Syntax
import           Language.ECMAScript3.Syntax.CodeGen
import           Language.Haskell.TH
import           Language.Haskell.TH.Lift
import           Network.HTTP.Types
import           Network.Wai
import           Network.Wai.Application.Static
import           System.Directory as System
import           System.Environment
import           System.Exit
import           System.FilePath
import           System.IO
import           System.IO.Temp
import           System.Process
import           WaiAppStatic.Storage.Embedded

import           Network.Wai.Shake.Ghcjs.Embedded

data BuildConfig = BuildConfig {
  mainFile :: FilePath
, sourceDirs :: [FilePath]
, projectDir :: FilePath
, projectExec :: Exec
} deriving (Eq, Show)

instance Lift BuildConfig where
  lift = \ case
    BuildConfig a b c d -> [|BuildConfig a b c d|]

getSourceDirs :: BuildConfig -> [FilePath]
getSourceDirs config = case sourceDirs config of
  [] -> ["."]
  dirs -> dirs

data Exec
  = Vanilla
  | Cabal
  | Stack
  deriving (Eq, Show)

instance Lift Exec where
  lift = \ case
    Vanilla -> [|Vanilla|]
    Cabal -> [|Cabal|]
    Stack -> [|Stack|]

addExec :: Exec -> String -> String
addExec exec command = case exec of
  Vanilla -> command
  Cabal -> "cabal exec -- " ++ command
  Stack -> "stack exec -- " ++ command

data Environment
  = Development
  | Production
  deriving (Eq, Show)

serveGhcjs :: BuildConfig -> Q Exp
serveGhcjs config = [| \ env -> case env of
  Development -> mkDevelopmentApp config
  Production -> $(mkProductionApp config)|]

-- * production app

mkProductionApp :: BuildConfig -> Q Exp
mkProductionApp config = do
  embeddable <- runIO $ wrapWithMessages $ do
    withSystemTempDirectory "wai-shake" $ \ buildDir -> do
      (result, outDir) <- ghcjsOrErrorToConsole buildDir config
      case result of
        Failure err -> do
          hPutStrLn stderr err
          die "ghcjs failed"
        Success -> mkSettingsFromDir outDir
  [|return $ staticApp $(mkSettings (return embeddable))|]
  where
    wrapWithMessages :: IO a -> IO a
    wrapWithMessages action = bracket
      (hPutStrLn stderr "=====> building client code with ghcjs")
      (const $ hPutStrLn stderr "=====> done")
      (const action)

-- * development app

mkDevelopmentApp :: BuildConfig -> IO Application
mkDevelopmentApp config = do
  mvar <- newMVar ()
  withSystemTempDirectory "wai-shake" $ \ buildDir -> do
    return $ developmentApp mvar buildDir config

mkSimpleApp :: (Request -> IO Response) -> Application
mkSimpleApp app request respond = app request >>= respond

developmentApp :: MVar () -> FilePath -> BuildConfig -> Application
developmentApp mvar buildDir config = mkSimpleApp $ \ request -> do
  createDirectoryIfMissing True buildDir
  outDir <- snd <$> forceToSingleThread mvar
    (ghcjsOrErrorToConsole buildDir config)
  case pathInfo request of
    [] -> serveFile "text/html" (outDir </> "index" <.> "html")
    [file] | ".js" == takeExtension (cs file) -> do
      fileExists <- System.doesFileExist (outDir </> cs file)
      if fileExists
        then serveFile "application/javascript" (outDir </> cs file)
        else send404
    _ -> send404
  where
    serveFile :: String -> FilePath -> IO Response
    serveFile contentType file = do
      c <- LBS.readFile file
      return $ responseLBS ok200
        [(mk (cs "Content-Type"), cs contentType <> cs "; charset=utf-8")] c

    send404 = return $ responseLBS notFound404 [] (cs "404 - Not Found")

forceToSingleThread :: MVar () -> IO a -> IO a
forceToSingleThread mvar action = modifyMVar mvar $ \ () -> do
  a <- action
  return ((), a)

-- * ghcjs

data Result
  = Success
  | Failure String
  deriving (Eq, Show)

ghcjsOrErrorToConsole :: FilePath -> BuildConfig -> IO (Result, FilePath)
ghcjsOrErrorToConsole buildDir config = do
  let outPattern = buildDir </> takeBaseName (mainFile config)
      outDir = outPattern <.> "jsexe"
      indexFile = outDir </> "index.html"
      options = shakeOptions{
        shakeFiles = buildDir </> "shake"
      }
  resultMVar <- newMVar Success
  withArgs [] $ shakeArgs options $ do
    want [indexFile]
    indexFile %> \ outFile -> do
      foundMainFile <- liftIO $ findMainFile config
      need [foundMainFile]
      unit $ cmd "rm -f" outFile
      (Exit c, Stderr output) <- cmd
        (Cwd (projectDir config))
        (addExec (projectExec config) "ghcjs -O0") (mainFile config)
        "-o" outPattern
        (map ("-i" ++) (sourceDirs config))
        ("-outputdir=" ++ buildDir </> "output")
      liftIO $ when (c /= ExitSuccess) $ do
        writeMVar resultMVar (Failure output)
        createErrorPage outDir output
      return ()
  result <- readMVar resultMVar
  return (result, outDir)

findMainFile :: BuildConfig -> IO FilePath
findMainFile config =
  lookup $ map
    (\ srcDir -> projectDir config </> srcDir </> mainFile config)
    (getSourceDirs config)
  where
    lookup :: [FilePath] -> IO FilePath
    lookup (a : r) = do
      exists <- System.doesFileExist a
      if exists
        then canonicalizePath a
        else lookup r
    lookup [] = die ("cannot find " ++ mainFile config)

createErrorPage :: FilePath -> String -> IO ()
createErrorPage dir msg = do
  let jsCode = createJsToConsole msg
  createDirectoryIfMissing True dir
  LBS.writeFile (dir </> "outputErrors.js") jsCode
  writeFile (dir </> "index.html") $ unindent [i|
    <!DOCTYPE html>
    <html>
      <head>
      </head>
      <body>
        <pre>
          #{msg}
        </pre>
      </body>
      <script language="javascript" src="outputErrors.js" defer></script>
    </html>
  |]

createJsToConsole :: String -> LBS.ByteString
createJsToConsole msg =
  let escape :: String -> String
      escape s =
        show $ prettyPrint (string (doublePercentSigns s) :: Expression ())
      doublePercentSigns = concatMap (\ c -> if c == '%' then "%%" else [c])
  in cs $ unlines $ map (\ line -> "console.log(" ++ escape line ++ ");") (lines msg)

writeMVar :: MVar a -> a -> IO ()
writeMVar mvar a = modifyMVar_ mvar (const $ return a)
