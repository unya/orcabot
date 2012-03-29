;;; Copyright 2012 Daniel Lowe All Rights Reserved.
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;     http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.

(in-package #:orcabot)

(defmodule url url-module ("url")
  (urls :accessor urls-of :initform nil))

(defmethod initialize-module ((module url-module) config)
  (setf (urls-of module) nil)
  (with-open-file (inf (orcabot-path "data/urls.lisp")
                       :direction :input
                       :if-does-not-exist nil)
    (when inf
      (setf (urls-of module) (read inf)))))

(defun save-urls (module)
  (with-open-file (ouf (orcabot-path "data/urls.lisp")
                       :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (write (urls-of module) :stream ouf)
    (terpri ouf)))

(defmethod handle-command ((module url-module)
                           (cmd (eql 'url))
                           message args)
  "url [<new url>] - add a url or get a random url"
  (cond
    (args
     (push (format nil "~{~a~^ ~}" args)
           (urls-of module))
     (save-urls module)
     (reply-to message "Url added."))
    (t
     (reply-to message "~a" (random-elt (urls-of module))))))
