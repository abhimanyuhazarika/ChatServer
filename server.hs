import ConcurrentUtils
import Network
import Control.Monad
import Control.Concurrent (forkIO)
import System.IO
import Text.Printf
import Control.Exception

-- <<main
main = withSocketsDo $ do
  sock <- listenOn (PortNumber (fromIntegral port))              
  printf "Listening on port %d\n" port
  forever $ do                                                   
     (handle, host, port) <- accept sock                         
     printf "Accepted connection from %s: %s\n" host (show port)
     forkFinally (talk handle) (\_ -> hClose handle)             

port :: Int
port = 44444
-- >>

-- <<talk
talk :: Handle -> IO ()
talk h = do
  hSetBuffering h LineBuffering                                
  loop                                                         
 where
  loop = do
    line <- hGetLine h                                         
    if line == "end"                                           
       then hPutStrLn h ("Thank you for using the " ++         
                         "Haskell doubling service.")
       else do hPutStrLn h (show (2 * (read line :: Integer))) 
               loop                                            
-- >>
