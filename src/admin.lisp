(in-package #:orca)

(defmodule admin admin-module ("echo" "action" "sayto"
                                      "ignore" "unignore"
                                      "join" "part" "quit" "nick"))

(defmethod handle-command ((self admin-module) (cmd (eql 'quit)) message args)
  "quit - make orca leave"
  (signal 'orca-exiting))

(defmethod handle-command ((self admin-module) (cmd (eql 'echo)) message args)
  "echo <stuff> - make orca say something"
  (when args
    (reply-to message "~{~a~^ ~}" args)))

(defmethod handle-command ((self admin-module) (cmd (eql 'action)) message args)
  "action <target> <something> - make orca do something to a target"
  (when (cdr args)
    (irc::action (connection message)
                 (first args)
                 (format nil "~{~a~^ ~}" (rest args)))))

(defmethod handle-command ((self admin-module) (cmd (eql 'sayto)) message args)
  "sayto <target> <something> - make orca say something to a target"
  (irc::privmsg (connection message)
               (first args)
               (format nil "~{~a~^ ~}" (rest args))))

(defmethod handle-command ((self admin-module) (cmd (eql 'ignore)) message args)
  "ignore <nick> - remove user from orca's awareness"
  (dolist (nick args)
    (pushnew (list 'deny :user nick) *access-control* :test 'string-equal))
  (if (cdr args)
      (reply-to message "Ok, I'm ignoring them.")
      (reply-to message "Ok, I'm ignoring ~a." (car args))))

(defmethod handle-command ((self admin-module) (cmd (eql 'unignore)) message args)
  (setf *access-control*
        (delete-if (lambda (nick)
                     (member nick args :test 'string-equal))
                   *access-control*))
  (if (cdr args)
      (reply-to message "Ok, I'm no longer ignoring them.")
      (reply-to message "Ok, I'm no longer ignoring ~a." (car args))))


(defmethod handle-command ((self admin-module) (cmd (eql 'join)) message args)
  "join <channel> - have orca join a channel"
  (dolist (channel args)
    (irc:join (connection message) channel)))

(defmethod handle-command ((self admin-module) (cmd (eql 'part)) message args)
  "part <channel> - make orca leave a channel"
  (dolist (channel args)
    (irc:part (connection message) channel)))

(defmethod handle-command ((self admin-module) (cmd (eql 'nick)) message args)
  "nick <channel> - make orca change its nick"
  (irc:nick (connection message) (first args)))
