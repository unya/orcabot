(require :asdf)
(require :swank)
(swank:create-server :port 40050 :style :spawn :dont-close t)
(require :orca)
(orca::background-orca-session (second *posix-argv*))
