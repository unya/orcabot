(in-package #:orcabot)

(define-condition weather-error ()
  ((message :accessor message-of :initarg :message)))

(defmethod print-object ((object weather-error) stream)
  (print-unreadable-object (object stream)
    (format stream "~a" (message-of object))))

(defvar *weather-throttles* (make-hash-table :test 'equal)
  "Table of throttling records, indexed by API key.  Used to ensure
  compliance with wunderground rate limits.")

(defclass weather-throttle ()
  ((minute-queries :accessor minute-queries-of :initarg :minute-queries :initform 0)
   (day-queries :accessor day-queries-of :initarg :day-queries :initform 0)
   (last-minute :accessor last-minute-of :initarg :last-minute)
   (last-day :accessor last-day-of :initarg :last-day)
   (max-per-minute :accessor max-per-minute-of :initarg :max-per-minute)
   (max-per-day :accessor max-per-day-of :initarg :max-per-day)))

(defun throttle-time (current-time)
  "Returns a value unique to the minute and day of the given current
time.  Used for throttling connections to wunderground."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time current-time 0)
    (declare (ignore sec))
    (values
     (encode-universal-time 0 min hour day month year 0)
     (encode-universal-time 0 0 0 day month year 0))))

(defun register-weather-key (key current-time max-per-day max-per-minute)
  "Registers a wunderground API key and sets the maximum per-day and
per-minute request limits.  This must be used before any queries are
made with the key."
  (multiple-value-bind (minute day)
      (throttle-time current-time)
    (setf (gethash key *weather-throttles*)
          (make-instance 'weather-throttle
                         :last-minute minute
                         :last-day day
                         :max-per-day max-per-day
                         :max-per-minute max-per-minute))))

(defun save-weather-config (path)
  "Saves throttling information."
  (with-open-file (ouf path
                       :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (maphash (lambda (api-key throttle)
               (write 
                (list api-key
                      :minute-queries (minute-queries-of throttle)
                      :day-queries (day-queries-of throttle)
                      :last-minute (last-minute-of throttle)
                      :last-day (last-day-of throttle))
                :stream ouf)
               (terpri ouf))
             *weather-throttles*)))

(defun load-weather-config (path)
  "Loads throttling information into registered keys."
  (when (probe-file path)
    (with-open-file (inf path :direction :input)
      (loop
         for entry = (read inf nil)
         while entry
         do
           (let ((throttle (gethash (first entry) *weather-throttles*)))
             (when throttle
               (setf (minute-queries-of throttle) (getf (rest entry) :minute-queries)
                     (day-queries-of throttle) (getf (rest entry) :day-queries)
                     (last-minute-of throttle) (getf (rest entry) :last-minute)
                     (last-day-of throttle) (getf (rest entry) :last-day))))))))

(defun throttle-query (key current-time)
  "Signals a weather-error if the key has used too queries for the
  wunderground rate limit."
  (let ((throttle (gethash key *weather-throttles*)))
    (when (null throttle)
      (error 'weather-error :message "Unconfigured API key in weather query throttle"))

    (when (and (null (max-per-day-of throttle))
               (null (max-per-minute-of throttle)))
      (return-from throttle-query nil))

    (multiple-value-bind (minute day)
        (throttle-time current-time)
      (when (> minute (last-minute-of throttle))
        (setf (minute-queries-of throttle) 0
              (last-minute-of throttle) minute))
      (when (> day (last-day-of throttle))
        (setf (day-queries-of throttle) 0
              (last-day-of throttle) day))
      (when (>= (day-queries-of throttle) (max-per-day-of throttle))
        (error 'weather-error :message "Maximum daily queries reached.  Try again tomorrow!"))
      (when (>= (minute-queries-of throttle) (max-per-minute-of throttle))
        (error 'weather-error :message "Too many queries.  Try again in a minute."))
      (incf (day-queries-of throttle))
      (incf (minute-queries-of throttle)))))

(defun find-dom-node (node tag-names)
  "Returns the node found by traversing a DOM hierarchy by tag names."
  (let ((child-node (find (first tag-names)
                          (dom:child-nodes node)
                          :key #'dom:node-name
                          :test #'string=)))
    (cond
      ((null child-node)
       nil)
      ((endp (rest tag-names))
       child-node)
      (t
       (find-dom-node child-node (rest tag-names))))))

(defun get-dom-text (node &rest tag-names)
  "Returns the text contained in the node in the DOM hierarchy."
  (let ((node (find-dom-node node tag-names)))
    (when node
      (dom:data (dom:first-child node)))))

(defun retrieve-http-document (&key scheme host path)
  "Retrieves an XML document via HTTP."
  (let ((uri (make-instance 'puri:uri :scheme scheme :host host :path path)))
    (multiple-value-bind (response status headers)
        (drakma:http-request (puri:render-uri uri nil))
      (declare (ignore headers))
      (cond
        ((/= status 200)
         (format t "weather server status = ~a" status)
         nil)
        (t
         (cxml:parse response (cxml-dom:make-dom-builder)))))))

(defun query-wunderground (key feature location)
  "Queries wunderground via the API.  May raise a weather-error."
  (throttle-query key (get-universal-time))
  (let ((doc (retrieve-http-document
              :scheme :http
              :host "api.wunderground.com"
              :path (format nil "/api/~a/~a/q/~a.xml"
                            key
                            feature
                            (drakma::url-encode location drakma:*drakma-default-external-format*)))))
    (cond
     ((null doc)
      (error 'weather-error :message "Weather server could not be reached"))
     ((get-dom-text doc "response" "error" "description")
      (error 'weather-error :message (get-dom-text doc "response" "error" "description")))
     ((get-dom-text doc "response" "results")
      (error 'weather-error :message "More than one possible location. Please be more specific."))
     (t
      (dom:first-child doc)))))

(defun retrieve-current-weather (key location)
  "Retrieves the current weather via wunderground.  Returns its stats
in multiple values.  May raise a weather-error."
  (let* ((root (query-wunderground key "conditions/forecast" location))
         (current (find-dom-node root '("current_observation")))
         (forecast (find-dom-node root '("forecast" "simpleforecast" "forecastdays" "forecastday"))))
    (values-list
     (append (list (get-dom-text current "display_location" "full"))
             (mapcar (lambda (field)
                       (get-dom-text current field))
                     '("weather" "relative_humidity" "wind_dir"
                       "temp_f" "dewpoint_f" "heat_index_f" "windchill_f"
                       "pressure_in" "wind_mph"
                       "temp_c" "dewpoint_c" "heat_index_c" "windchill_c"
                       "pressure_mb" "wind_kph"))
             (list 
              (get-dom-text forecast "conditions")
              (get-dom-text forecast "high" "fahrenheit")
              (get-dom-text forecast "low" "fahrenheit")
              (get-dom-text forecast "high" "celsius")
              (get-dom-text forecast "low" "celsius"))))))

;;; End of wunderground interface

(defun load-location-db (path)
  (let ((result (make-hash-table :test 'equal)))
    (with-open-file (inf path :if-does-not-exist nil)
      (when inf
        (loop
           for tuple = (read inf nil)
           while tuple
           do (setf (gethash (first tuple) result)
                    (second tuple)))))
    result))

(defun save-location-db (db path)
  (with-open-file (ouf path :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (maphash (lambda (k v)
               (print (list k v) ouf))
             db)))

(defmodule weather weather-module ("weather")
  (api-key :accessor api-key-of :initform nil)
  (default-location :accessor default-location-of :initform nil)
  (locations :accessor locations-of :initform nil)
  (warning-poll :accessor warning-poll-of :initform nil))

(defmethod initialize-module ((module weather-module) config)
  (let ((module-conf (rest (assoc 'weather config))))
    (setf (api-key-of module) (getf module-conf :api-key))
    (setf (default-location-of module) (getf module-conf :default-location))
    (setf (warning-poll-of module) (getf module-conf :warning-poll))
    (register-weather-key (api-key-of module)
                          (get-universal-time)
                          (getf module-conf :max-per-day)
                          (getf module-conf :max-per-minute)))
  (setf (locations-of module)
        (load-location-db (orcabot-path "data/weather-locations.lisp")))
  (load-weather-config (orcabot-path "data/weather-throttle.lisp"))
  
  (when (null (api-key-of module))
    (format t "WARNING: Missing API key for WEATHER module~%")))

(defmethod about-module ((module weather-module) stream)
  (format stream "- Weather information provided by wunderground.com~%"))

(defun parse-weather-args (module message raw-args)
  (let (opts args)
    (dolist (arg raw-args)
      (if (string= "-" arg :end2 1)
          (push arg opts)
          (push arg args)))
    (values
     (find "--metric" opts :test #'string=)
     (find "--set" opts :test #'string=)
     (cond
       (args
        (join-string " " (nreverse args)))
       ((gethash (source message) (locations-of module)))
       ((gethash (first (arguments message)) (locations-of module)))
       (t
        (default-location-of module))))))

(defun display-weather (module message metricp location)
  (handler-case
      (multiple-value-bind (city weather humidity wind-dir
                                 temp-f dewpoint-f heat-index-f windchill-f
                                 pressure-in wind-mph
                                 temp-c dewpoint-c heat-index-c windchill-c
                                 pressure-mb wind-kph
                                 forecast high-f low-f high-c low-c)
          (retrieve-current-weather (api-key-of module) location)

        (save-weather-config (orcabot-path "data/weather-throttle.lisp"))

        (reply-to message "Current weather for ~a" city)
        (cond
          (metricp
           (reply-to message "~a, Temp: ~aC, Dewpoint: ~aC, ~
                           ~@[Heat Index: ~aC, ~]~
                           ~@[Wind Chill: ~aC, ~]~
                           Humidity: ~a, Pressure: ~amb, ~
                           Wind: ~a ~akph"
                     weather temp-c dewpoint-c
                     (if (string= heat-index-c "NA") nil heat-index-c)
                     (if (string= windchill-c "NA") nil windchill-c)
                     humidity pressure-mb
                     wind-dir wind-kph)
           (reply-to message "Forecast: ~a, High: ~aC, Low: ~aC" forecast high-c low-c))
          (t
           (reply-to message "~a, Temp: ~aF, Dewpoint: ~aF, ~
                           ~@[Heat Index: ~aF, ~]~
                           ~@[Wind Chill: ~aF, ~]~
                           Humidity: ~a, Pressure: ~ain, ~
                           Wind: ~a ~amph"
                     weather temp-f dewpoint-f
                     (if (string= heat-index-f "NA") nil heat-index-f)
                     (if (string= windchill-f "NA") nil windchill-f)
                     humidity pressure-in
                     wind-dir wind-mph)
           (reply-to message "Forecast: ~a, High: ~aF, Low: ~aF" forecast high-f low-f))))
    (weather-error (err)
      (save-weather-config (orcabot-path "data/weather-throttle.lisp"))
      (reply-to message "~a: ~a" (source message) (message-of err)))))


(defmethod handle-command ((module weather-module) (cmd (eql 'weather))
                           message args)
  "weather [--metric] <location> - show current conditions and the day's forecast
weather [--set] <location> - set the channel default location
"
  (multiple-value-bind (metricp setp location)
      (parse-weather-args module message args)
    (cond
      ((not setp)
       (display-weather module message metricp location))
      ((null args)
       (reply-to message "You must specify a location to set."))
      ((message-target-is-channel-p message)
       (setf (gethash (first (arguments message)) (locations-of module)) location)
       (save-location-db (locations-of module)
                         (orcabot-path "data/weather-locations.lisp"))
       (reply-to message "The default location for ~a is now ~a."
                 (first (arguments message))
                 location))
      (t
       (reply-to message "You cannot --set in a private message." location)))))
