;;; reference-explorer-source-lookup-homebrew.el --- Homebrew GNU Lookup setup -*- lexical-binding: t -*-

;;; Commentary:

;; Optional helper for a GNU Lookup installation supplied by Homebrew.  Load
;; and call `reference-explorer-source-lookup-homebrew-configure' before loading
;; `reference-explorer-source-lookup'.  The core lookup UI does not call it.

;;; Code:

(require 'reference-explorer)
(require 'seq)

(defcustom reference-explorer-source-lookup-homebrew-prefix nil
  "Homebrew prefix used to locate GNU Lookup, EBLook, and MeCab.
Nil infers the prefix from the environment, `brew', or common locations."
  :type '(choice (const :tag "Infer" nil) directory)
  :group 'reference-explorer)

(defvar lookup-kanji-mecab-coding-system)
(defvar lookup-kanji-mecab-program-name)
(defvar lookup-kanji-scheme)
(defvar ndeb-program-name)

(defun reference-explorer-source-lookup-homebrew--prefix ()
  "Return the configured or inferred Homebrew prefix."
  (or reference-explorer-source-lookup-homebrew-prefix
      (getenv "HOMEBREW_PREFIX")
      (when-let ((program (executable-find "brew")))
        (file-name-directory
         (directory-file-name (file-name-directory program))))
      (seq-find #'file-directory-p '("/opt/homebrew" "/usr/local"))))

(defun reference-explorer-source-lookup-homebrew--program (prefix name)
  "Return executable NAME below PREFIX or from the active PATH."
  (let ((program (expand-file-name (concat "bin/" name) prefix)))
    (if (file-executable-p program) program (executable-find name))))

;;;###autoload
(defun reference-explorer-source-lookup-homebrew-configure ()
  "Configure GNU Lookup, EBLook, and its MeCab backend from Homebrew.
Call this before loading `reference-explorer-source-lookup' so `lookup-kanji' sees
the selected backend during initialization."
  (interactive)
  (let* ((prefix (or (reference-explorer-source-lookup-homebrew--prefix)
                     (user-error "Homebrew prefix is unavailable")))
         (lookup-directory
          (expand-file-name
           "opt/emacs-lookup/share/emacs/site-lisp/lookup" prefix)))
    (when (file-directory-p lookup-directory)
      (add-to-list 'load-path lookup-directory))
    (setq lookup-kanji-scheme 'mecab
          lookup-kanji-mecab-coding-system 'utf-8)
    (when-let ((eblook
                (reference-explorer-source-lookup-homebrew--program prefix "eblook")))
      (setq ndeb-program-name eblook))
    (when-let ((mecab
                (reference-explorer-source-lookup-homebrew--program prefix "mecab")))
      (setq lookup-kanji-mecab-program-name mecab))))

(provide 'reference-explorer-source-lookup-homebrew)
;;; reference-explorer-source-lookup-homebrew.el ends here
