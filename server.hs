talk :: Handle -> IO ()
talk h = do
  hSetBuffering h LineBuffering                              
  loop                                                        
 where
  loop = do
    line <- hGetLine h                                         
    if line == "end"                                          
    then hPutStrLn h ("Program ends")
       else do hPutStrLn h (show (2* (read line :: Integer)))
               loop   
