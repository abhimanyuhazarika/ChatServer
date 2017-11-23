module Client where

-- Kill server and all clients
killService :: Socket -> IO ()
killService originalSocket = do
    clog "Killing Service..."
    shutdown originalSocket ShutdownBoth
    close originalSocket

-- Basic "Helo" response
helo :: Handle -> String -> String -> IO ()
helo hdl text port = do
    clog $ "Responding to HELO command with params : " ++ text
    hostname <- getHostNameIfDockerOrNot
    sendResponse hdl $ "HELO " ++ text ++ "\nIP:" ++ hostname ++ "\nPort:" ++ port ++ "\nStudentID:17314158"
