;;; reference-explorer-phrase-segmenter.el --- Phrase segmenter protocol -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Define the context and result protocol used by pluggable phrase segmenters.
;; Language-specific analysis and mode-specific visible-text adapters live in
;; separate modules.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup reference-explorer-phrase-segmenter nil
  "Phrase segmentation for Reference Explorer."
  :group 'editing)

(cl-defstruct (reference-explorer-phrase-segmenter-context
               (:constructor reference-explorer-phrase-segmenter-context-create))
  "Buffer coordinates supplied to a phrase segmenter."
  position
  start
  end)

(cl-defstruct (reference-explorer-phrase-segmenter-result
               (:constructor reference-explorer-phrase-segmenter-result-create))
  "Candidate bounds and the initially selected bounds from a segmenter."
  candidates
  initial)

(defcustom reference-explorer-phrase-segmenters
  '(reference-explorer-phrase-segmenter-mecab
    reference-explorer-phrase-segmenter-emacs)
  "Ordered phrase segmenter functions.
Each function receives a `reference-explorer-phrase-segmenter-context' and
returns a `reference-explorer-phrase-segmenter-result', or nil when it does not
handle the text.  Candidate bounds are in buffer coordinates and should be in
the order consumers use for expansion and contraction."
  :type '(repeat function)
  :group 'reference-explorer-phrase-segmenter)

(defcustom reference-explorer-phrase-segmenter-context-functions
  '(reference-explorer-phrase-segmenter-org-context
    reference-explorer-phrase-segmenter-default-context)
  "Ordered functions used to create a segmenter context.
Each function receives a buffer POSITION and returns a
`reference-explorer-phrase-segmenter-context', or nil when it does not apply."
  :type '(repeat function)
  :group 'reference-explorer-phrase-segmenter)

(autoload 'reference-explorer-phrase-segmenter-emacs
  "reference-explorer-phrase-segmenter-emacs")
(autoload 'reference-explorer-phrase-segmenter-mecab
  "reference-explorer-phrase-segmenter-mecab")
(autoload 'reference-explorer-phrase-segmenter-org-context
  "reference-explorer-phrase-segmenter-org")

(defun reference-explorer-phrase-segmenter-default-context (position)
  "Return an unrestricted phrase segmenter context for POSITION."
  (reference-explorer-phrase-segmenter-context-create :position position))

(defun reference-explorer-phrase-segmenter--position (value owner role)
  "Normalize VALUE as a current-buffer position for OWNER's ROLE."
  (let ((position
         (cond
          ((markerp value)
           (unless (and (marker-position value)
                        (eq (marker-buffer value) (current-buffer)))
             (error "%s returned an invalid %s marker: %S"
                    owner role value))
           (marker-position value))
          ((integerp value) value)
          (t
           (error "%s returned an invalid %s position: %S"
                  owner role value)))))
    (unless (<= (point-min) position (point-max))
      (error "%s returned an out-of-buffer %s position: %S"
             owner role value))
    position))

(defun reference-explorer-phrase-segmenter--context (&optional position)
  "Return the first context produced for POSITION or point."
  (let ((position (or position (point))))
    (cl-loop for function in reference-explorer-phrase-segmenter-context-functions
             for context = (funcall function position)
             when context
             return
             (progn
               (unless (reference-explorer-phrase-segmenter-context-p context)
                 (error "Phrase context function %s returned invalid data: %S"
                        function context))
               (setq context
                     (copy-reference-explorer-phrase-segmenter-context context))
               (let ((resolved
                      (reference-explorer-phrase-segmenter--position
                       (reference-explorer-phrase-segmenter-context-position
                        context)
                       function "context"))
                     (start
                      (reference-explorer-phrase-segmenter-context-start context))
                     (end
                      (reference-explorer-phrase-segmenter-context-end context)))
                 (if (or start end)
                     (unless (and start end)
                       (error "Phrase context function %s returned incomplete bounds"
                              function))
                   (setq start nil end nil))
                 (when start
                   (setq start
                         (reference-explorer-phrase-segmenter--position
                          start function "context start")
                         end
                         (reference-explorer-phrase-segmenter--position
                          end function "context end"))
                   (unless (and (< start end)
                                (<= start resolved)
                                (< resolved end))
                     (error "Phrase context function %s returned invalid bounds"
                            function)))
                 (setf
                  (reference-explorer-phrase-segmenter-context-position context)
                  resolved
                  (reference-explorer-phrase-segmenter-context-start context)
                  start
                  (reference-explorer-phrase-segmenter-context-end context)
                  end))
               context))))

(defun reference-explorer-phrase-segmenter--normalize-bounds
    (segmenter bounds context)
  "Normalize and validate SEGMENTER BOUNDS against CONTEXT."
  (unless (consp bounds)
    (error "Phrase segmenter %s returned invalid bounds: %S"
           segmenter bounds))
  (let* ((start
          (reference-explorer-phrase-segmenter--position
           (car bounds) segmenter "candidate start"))
         (end
          (reference-explorer-phrase-segmenter--position
           (cdr bounds) segmenter "candidate end"))
         (position
          (reference-explorer-phrase-segmenter-context-position context))
         (context-start
          (reference-explorer-phrase-segmenter-context-start context))
         (context-end
          (reference-explorer-phrase-segmenter-context-end context)))
    (unless (< start end)
      (error "Phrase segmenter %s returned empty or reversed bounds: %S"
             segmenter bounds))
    (unless (and (<= start position) (<= position end))
      (error "Phrase segmenter %s returned bounds outside the origin: %S"
             segmenter bounds))
    (when (and context-start
               (not (and (<= context-start start) (<= end context-end))))
      (error "Phrase segmenter %s returned bounds outside its context: %S"
             segmenter bounds))
    (cons start end)))

(defun reference-explorer-phrase-segmenter--validate-result
    (segmenter result context)
  "Validate and normalize RESULT produced by SEGMENTER for CONTEXT."
  (unless (reference-explorer-phrase-segmenter-result-p result)
    (error "Phrase segmenter %s returned an invalid result: %S"
           segmenter result))
  (let ((candidates
         (reference-explorer-phrase-segmenter-result-candidates result))
        (initial
         (reference-explorer-phrase-segmenter-result-initial result)))
    (unless (consp candidates)
      (error "Phrase segmenter %s returned invalid candidates: %S"
             segmenter candidates))
    (setq candidates
          (mapcar
           (lambda (bounds)
             (reference-explorer-phrase-segmenter--normalize-bounds
              segmenter bounds context))
           candidates))
    (if initial
        (let* ((normalized
                (reference-explorer-phrase-segmenter--normalize-bounds
                 segmenter initial context))
               (selected (member normalized candidates)))
          (unless selected
            (error "Phrase segmenter %s selected a non-candidate: %S"
                   segmenter initial))
          (setq initial (car selected)))
      (setq initial (car candidates)))
    (setf (reference-explorer-phrase-segmenter-result-candidates result)
          candidates
          (reference-explorer-phrase-segmenter-result-initial result)
          initial))
  result)

(defun reference-explorer-phrase-segmenter-result-at-point (&optional position)
  "Return the first phrase segmentation result for POSITION or point."
  (when-let ((context (reference-explorer-phrase-segmenter--context position)))
    (save-excursion
      (goto-char (reference-explorer-phrase-segmenter-context-position context))
      (cl-loop for segmenter in reference-explorer-phrase-segmenters
               for result = (funcall segmenter context)
               when result
               return (reference-explorer-phrase-segmenter--validate-result
                       segmenter
                       (copy-reference-explorer-phrase-segmenter-result
                        result)
                       context)))))

(defun reference-explorer-phrase-segmenter-visible-position-at-point
    (&optional position)
  "Return the visible text position represented by POSITION or point."
  (when-let ((context (reference-explorer-phrase-segmenter--context position)))
    (reference-explorer-phrase-segmenter-context-position context)))

(defun reference-explorer-phrase-segmenter-candidate-bounds-at-point
    (&optional position)
  "Return phrase candidate bounds at POSITION or point."
  (when-let ((result
              (reference-explorer-phrase-segmenter-result-at-point position)))
    (reference-explorer-phrase-segmenter-result-candidates result)))

(defun reference-explorer-phrase-segmenter-bounds-at-point (&optional position)
  "Return the initially selected phrase bounds at POSITION or point."
  (when-let ((result
              (reference-explorer-phrase-segmenter-result-at-point position)))
    (reference-explorer-phrase-segmenter-result-initial result)))

(defun reference-explorer-phrase-segmenter-candidates-at-point
    (&optional position)
  "Return phrase candidates at POSITION or point without text properties."
  (mapcar
   (lambda (bounds)
     (buffer-substring-no-properties (car bounds) (cdr bounds)))
   (reference-explorer-phrase-segmenter-candidate-bounds-at-point position)))

(defun reference-explorer-phrase-segmenter-at-point (&optional position)
  "Return the initially selected phrase at POSITION or point."
  (when-let ((bounds
              (reference-explorer-phrase-segmenter-bounds-at-point position)))
    (buffer-substring-no-properties (car bounds) (cdr bounds))))

(provide 'reference-explorer-phrase-segmenter)
;;; reference-explorer-phrase-segmenter.el ends here
