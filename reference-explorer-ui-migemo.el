;;; reference-explorer-ui-migemo.el --- Migemo filtering for reference UI -*- lexical-binding: t -*-

;;; Commentary:

;; Optional extension of `reference-explorer-ui' for hosts that have
;; already configured Migemo and Orderless.  Loading this file installs a
;; converted-mode completion style; neither the provider dispatcher nor the
;; shared UI loads it automatically.

;;; Code:

(require 'reference-explorer-ui)
(require 'migemo)
(require 'orderless)

(defcustom reference-explorer-ui-migemo-orderless-matching-styles
  '(orderless-prefixes orderless-flex)
  "Orderless matchers tried after the Migemo matcher."
  :type '(repeat function)
  :group 'reference-explorer-ui)

(defun reference-explorer-ui-migemo-orderless-regexp (component)
  "Return a Migemo regular expression for Orderless COMPONENT."
  (let ((pattern (migemo-get-pattern component)))
    (condition-case nil
        (progn (string-match-p pattern "") pattern)
      (invalid-regexp nil))))

(orderless-define-completion-style reference-explorer-ui-migemo-orderless
  (orderless-matching-styles
   (cons 'reference-explorer-ui-migemo-orderless-regexp
         reference-explorer-ui-migemo-orderless-matching-styles)))

(setq reference-explorer-ui-converted-completion-style
      'reference-explorer-ui-migemo-orderless)

(provide 'reference-explorer-ui-migemo)
;;; reference-explorer-ui-migemo.el ends here
