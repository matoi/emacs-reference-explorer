;;; reference-explorer-phrase-segmenter-mecab.el --- MeCab phrase segmenter -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Select Japanese phrase candidates using MeCab.  This module owns both the
;; candidate construction and the policy for choosing the initial candidate.

;;; Code:

(require 'cl-lib)
(require 'reference-explorer-phrase-segmenter)
(require 'seq)

(defcustom reference-explorer-phrase-segmenter-mecab-program "mecab"
  "MeCab executable used to identify Japanese phrases."
  :type 'string
  :group 'reference-explorer-phrase-segmenter)

(defcustom reference-explorer-phrase-segmenter-mecab-initial-minimum-length 2
  "Minimum character length of the preferred initial MeCab phrase.
The shortest candidate meeting this length is preferred.  When none does, the
longest available candidate is used."
  :type 'natnum
  :group 'reference-explorer-phrase-segmenter)

(defun reference-explorer-phrase-segmenter-mecab--japanese-character-p
    (character)
  "Return non-nil when CHARACTER belongs to a Japanese writing script."
  (and character (aref (char-category-set character) ?j)))

(defun reference-explorer-phrase-segmenter-mecab--byte-to-character
    (string offset)
  "Convert UTF-8 byte OFFSET in STRING to a character offset."
  (length
   (decode-coding-string
    (substring (encode-coding-string string 'utf-8) 0 offset)
    'utf-8)))

(defun reference-explorer-phrase-segmenter-mecab--nodes (string)
  "Return MeCab nodes for STRING as (SURFACE START END FEATURES)."
  (when-let ((program
              (executable-find
               reference-explorer-phrase-segmenter-mecab-program)))
    (with-temp-buffer
      (insert string "\n")
      (let ((coding-system-for-read 'utf-8)
            (coding-system-for-write 'utf-8))
        (when (zerop
               (call-process-region
                (point-min) (point-max) program t t nil
                "-F" "%m\t%ps\t%pe\t%H\\n" "-E" ""))
          (goto-char (point-min))
          (let (nodes)
            (while (re-search-forward
                    "^\\([^\t]*\\)\t\\([0-9]+\\)\t\\([0-9]+\\)\t\\(.*\\)$"
                    nil t)
              (push (list (match-string-no-properties 1)
                          (string-to-number (match-string 2))
                          (string-to-number (match-string 3))
                          (split-string (match-string-no-properties 4) ","))
                    nodes))
            (nreverse nodes)))))))

(defun reference-explorer-phrase-segmenter-mecab--compound-node-p (node)
  "Return non-nil when MeCab NODE can participate in a compound."
  (member (car (nth 3 node)) '("名詞" "接頭詞")))

(defun reference-explorer-phrase-segmenter-mecab--adjacent-p (left right)
  "Return non-nil when nodes LEFT and RIGHT have no gap."
  (= (nth 2 left) (nth 1 right)))

(defun reference-explorer-phrase-segmenter-mecab--compound-bounds
    (nodes index)
  "Return compound byte bounds in NODES containing node INDEX."
  (let ((node (nth index nodes)))
    (if (not (reference-explorer-phrase-segmenter-mecab--compound-node-p node))
        (list (cons (nth 1 node) (nth 2 node)))
      (let ((first index)
            (last index))
        (while (and (> first 0)
                    (reference-explorer-phrase-segmenter-mecab--compound-node-p
                     (nth (1- first) nodes))
                    (reference-explorer-phrase-segmenter-mecab--adjacent-p
                     (nth (1- first) nodes) (nth first nodes)))
          (setq first (1- first)))
        (while (and (< last (1- (length nodes)))
                    (reference-explorer-phrase-segmenter-mecab--compound-node-p
                     (nth (1+ last) nodes))
                    (reference-explorer-phrase-segmenter-mecab--adjacent-p
                     (nth last nodes) (nth (1+ last) nodes)))
          (setq last (1+ last)))
        (sort
         (cl-loop for start from first to index append
                  (cl-loop for end from index to last
                           collect (cons (nth 1 (nth start nodes))
                                         (nth 2 (nth end nodes)))))
         (lambda (left right)
           (> (- (cdr left) (car left))
              (- (cdr right) (car right)))))))))

(defun reference-explorer-phrase-segmenter-mecab--initial (candidates)
  "Return the preferred initial bounds from CANDIDATES."
  (let ((eligible
         (seq-filter
          (lambda (bounds)
            (>= (- (cdr bounds) (car bounds))
                reference-explorer-phrase-segmenter-mecab-initial-minimum-length))
          candidates)))
    (if eligible
        (seq-reduce
         (lambda (preferred bounds)
           (if (< (- (cdr bounds) (car bounds))
                  (- (cdr preferred) (car preferred)))
               bounds
             preferred))
         (cdr eligible) (car eligible))
      (car candidates))))

(defun reference-explorer-phrase-segmenter-mecab (context)
  "Return Japanese phrase candidates for CONTEXT using MeCab."
  (let ((position
         (reference-explorer-phrase-segmenter-context-position context)))
    (when (reference-explorer-phrase-segmenter-mecab--japanese-character-p
           (char-after position))
      (let* ((text-start
              (or (reference-explorer-phrase-segmenter-context-start context)
                  (line-beginning-position)))
             (text-end
              (or (reference-explorer-phrase-segmenter-context-end context)
                  (line-end-position)))
             (text (buffer-substring-no-properties text-start text-end))
             (byte-position
              (string-bytes
               (buffer-substring-no-properties text-start position))))
        (when-let* ((nodes
                     (reference-explorer-phrase-segmenter-mecab--nodes text))
                    (index
                     (seq-position
                      nodes byte-position
                      (lambda (entry byte)
                        (and (<= (nth 1 entry) byte)
                             (< byte (nth 2 entry)))))))
          (let ((candidates
                 (mapcar
                  (lambda (bounds)
                    (cons
                     (+ text-start
                        (reference-explorer-phrase-segmenter-mecab--byte-to-character
                         text (car bounds)))
                     (+ text-start
                        (reference-explorer-phrase-segmenter-mecab--byte-to-character
                         text (cdr bounds)))))
                  (reference-explorer-phrase-segmenter-mecab--compound-bounds
                   nodes index))))
            (reference-explorer-phrase-segmenter-result-create
             :candidates candidates
             :initial
             (reference-explorer-phrase-segmenter-mecab--initial
              candidates))))))))

(provide 'reference-explorer-phrase-segmenter-mecab)
;;; reference-explorer-phrase-segmenter-mecab.el ends here
