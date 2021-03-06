(defpackage #:simple-actors/ipc
  (:use #:common-lisp #:bordeaux-threads)
  (:documentation
   "This package provides a basic method for threads to send messages to each other.")

  (:export #:send-message #:get-message #:make-mailbox))

(in-package #:simple-actors/ipc)

(define-condition mailbox-is-empty () ())
(define-condition semaphore-timeout (simple-error) ())

(defstruct simple-process-mailbox
  (lock (make-lock) :type lock)
  (blocker (make-semaphore) :type semaphore)
  (unread-messages nil :type list)
  (read-messages nil :type list))

(defun make-mailbox ()
  (make-simple-process-mailbox))

(defmacro without-mutex ((mutex) &body body)
  `(unwind-protect
	(progn
	  #+sbcl (sb-sys:without-interrupts
		   (sb-thread:release-mutex ,mutex :if-not-owner :warn))
	  #-sbcl (release-lock ,mutex)
	  ,@body)
     #+sbcl (sb-sys:without-interrupts
	      (sb-thread:grab-mutex ,mutex))
     #-sbcl (acquire-lock ,mutex)))

(defun send-message (mailbox message)
  "Sends a MESSAGE to the specified MAILBOX. The MESSAGE can be any Lisp value. If
the mailbox does not exist, it will be created.

See also: GET-MESSAGE"
  (with-lock-held ((slot-value mailbox 'lock))
    (push message (slot-value mailbox 'unread-messages))
    (signal-semaphore (slot-value mailbox 'blocker))
    nil))

(defun get-message (mailbox &key error-if-empty (default-value nil)
		    (non-blocking nil) (timeout nil))
  "Reads a message from the given MAILBOX object. By default, if there are no messages,
GET-MESSAGE will block until a message arrives in the MAILBOX.

Keys:

  :NON-BLOCKING   If set to T, then GET-MESSAGE will return immediately even if there are no messages.
  :DEFAULT-VALUE  In non-blocking mode, this is the default return value if there are no messages.
  :ERROR-IF-EMPTY If set to T :NON-BLOCKING is also T, and there are no messages, a condition of type
                  'MAILBOX-IS-EMPTY will be signalled.

See also: SEND-MESSAGE, MAILBOX"
  (with-lock-held ((slot-value mailbox 'lock))
    (unless non-blocking
      (let ((sem (slot-value mailbox 'blocker)))
	(without-mutex ((slot-value mailbox 'lock))
	  (unless (wait-on-semaphore sem :timeout timeout)
	    (error 'semaphore-timeout)))))
    (cond ((slot-value mailbox 'read-messages)
	   (when non-blocking
	     (wait-on-semaphore (slot-value mailbox 'blocker) :timeout 0))
	   (pop (slot-value mailbox 'read-messages)))
	  ((slot-value mailbox 'unread-messages)
	   (when non-blocking
	     (wait-on-semaphore (slot-value mailbox 'blocker) :timeout 0))
	   (setf (slot-value mailbox 'read-messages) (reverse (slot-value mailbox 'unread-messages)))
	   (setf (slot-value mailbox 'unread-messages) nil)
	   (pop (slot-value mailbox 'read-messages)))
	  (error-if-empty
	   (error 'mailbox-is-empty))
	  (t default-value))))
