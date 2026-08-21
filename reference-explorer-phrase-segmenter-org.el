;;; reference-explorer-phrase-segmenter-org.el --- Org phrase context -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Restrict phrase segmentation to the visible description of an Org link.

;;; Code:

(require 'reference-explorer-phrase-segmenter)

(declare-function org-element-context "org-element" (&optional element))
(declare-function org-element-property "org-element"
                  (property node &optional dflt force-undefer))
(declare-function org-element-type "org-element" (element))

(defun reference-explorer-phrase-segmenter-org-context (position)
  "Return an Org visible-description context for POSITION, or nil."
  (when (derived-mode-p 'org-mode)
    (require 'org-element)
    (save-excursion
      (goto-char position)
      (let* ((link (org-element-context))
             (start
              (and (eq (org-element-type link) 'link)
                   (org-element-property :contents-begin link)))
             (end
              (and start (org-element-property :contents-end link))))
        (when (and start end (< start end))
          (reference-explorer-phrase-segmenter-context-create
           :position (min (max position start) (1- end))
           :start start
           :end end))))))

(provide 'reference-explorer-phrase-segmenter-org)
;;; reference-explorer-phrase-segmenter-org.el ends here
