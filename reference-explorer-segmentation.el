;;; reference-explorer-segmentation.el --- Pluggable phrase selection -*- lexical-binding: t -*-

;;; Commentary:

;; Select phrases independently of the command that consumes them.  Backends
;; are tried in order, allowing language-specific segmenters to precede the
;; ordinary Emacs word-boundary fallback.  The bundled Japanese backend uses
;; MeCab when it is available.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'thingatpt)

(defgroup reference-explorer-segmentation nil
  "Phrase selection for Reference Explorer."
  :group 'editing)

(defcustom reference-explorer-segmentation-mecab-program "mecab"
  "MeCab executable used to identify Japanese words.
When it is unavailable, word recognition falls back to Emacs."
  :type 'string
  :group 'reference-explorer-segmentation)

(defcustom reference-explorer-segmentation-backends
  '(reference-explorer-segmentation-mecab-backend
    reference-explorer-segmentation-emacs-backend)
  "Ordered functions used to find phrase bounds at point.
Each function receives POSITION, REGION-START, and REGION-END.  It returns
bounds ordered from the most useful or longest candidate to the shortest, or
nil when it does not handle the text.  REGION-START and REGION-END restrict
selection to visible text, such as an Org link description."
  :type '(repeat function)
  :group 'reference-explorer-segmentation)

(declare-function org-element-context "org-element" (&optional element))
(declare-function org-element-property "org-element"
                  (property node &optional dflt force-undefer))
(declare-function org-element-type "org-element" (element))

(defun reference-explorer-segmentation--org-visible-context (position)
  "Return visible Org context as (POSITION BEGIN END).
Org can leave point in hidden brackets or the target at either visual edge of
a descriptive link.  Such positions are clamped to its visible description.
BEGIN and END delimit that description, or are nil outside a descriptive
link."
  (if (not (derived-mode-p 'org-mode))
      (list position nil nil)
    (require 'org-element)
    (save-excursion
      (goto-char position)
      (let* ((link (org-element-context))
             (contents-begin
              (and (eq (org-element-type link) 'link)
                   (org-element-property :contents-begin link)))
             (contents-end
              (and contents-begin
                   (org-element-property :contents-end link))))
        (cond
         ((not (and contents-begin contents-end
                    (< contents-begin contents-end)))
          (list position nil nil))
         (t
          (list (min (max position contents-begin) (1- contents-end))
                contents-begin contents-end)))))))

(defun reference-explorer-segmentation-visible-position-at-point (&optional position)
  "Return the visible text position represented by POSITION or point.
In an Org descriptive link, hidden markup at either visual edge is mapped
onto the corresponding character in the visible description."
  (car (reference-explorer-segmentation--org-visible-context
        (or position (point)))))

(defun reference-explorer-segmentation--japanese-character-p (character)
  "Return non-nil when CHARACTER belongs to a Japanese writing script."
  (and character (aref (char-category-set character) ?j)))

(defun reference-explorer-segmentation--byte-offset-to-character (string offset)
  "Convert UTF-8 byte OFFSET in STRING to a character offset."
  (length
   (decode-coding-string
    (substring (encode-coding-string string 'utf-8) 0 offset)
    'utf-8)))

(defun reference-explorer-segmentation--mecab-nodes (string)
  "Return MeCab nodes for STRING as (SURFACE START-BYTE END-BYTE FEATURES).
Return nil when MeCab is unavailable or cannot analyze the input."
  (when-let ((program (executable-find reference-explorer-segmentation-mecab-program)))
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
                          (split-string
                           (match-string-no-properties 4) ","))
                    nodes))
            (nreverse nodes)))))))

(defun reference-explorer-segmentation--compound-node-p (node)
  "Return non-nil when MeCab NODE can participate in a compound word."
  (let ((part-of-speech (car (nth 3 node))))
    (member part-of-speech '("名詞" "接頭詞"))))

(defun reference-explorer-segmentation--adjacent-nodes-p (left right)
  "Return non-nil when MeCab nodes LEFT and RIGHT have no gap."
  (= (nth 2 left) (nth 1 right)))

(defun reference-explorer-segmentation--compound-bound-candidates (nodes index)
  "Return compound byte bounds in NODES containing node INDEX.
Candidates are ordered from longest to shortest.  Particles, auxiliaries,
punctuation, and whitespace terminate a compound."
  (let ((node (nth index nodes)))
    (if (not (reference-explorer-segmentation--compound-node-p node))
        (list (cons (nth 1 node) (nth 2 node)))
      (let ((first index)
            (last index))
        (while (and (> first 0)
                    (reference-explorer-segmentation--compound-node-p
                     (nth (1- first) nodes))
                    (reference-explorer-segmentation--adjacent-nodes-p
                     (nth (1- first) nodes) (nth first nodes)))
          (setq first (1- first)))
        (while (and (< last (1- (length nodes)))
                    (reference-explorer-segmentation--compound-node-p
                     (nth (1+ last) nodes))
                    (reference-explorer-segmentation--adjacent-nodes-p
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

(defun reference-explorer-segmentation-mecab-backend
    (position &optional region-start region-end)
  "Return MeCab word-bound candidates containing POSITION.
The current logical line is sent to MeCab unless REGION-START and REGION-END
restrict it, as for an Org link description.  Consecutive noun and prefix nodes
form compound candidates ordered from longest to shortest."
  (when (reference-explorer-segmentation--japanese-character-p
         (char-after position))
    (let* ((text-start (or region-start (line-beginning-position)))
           (text-end (or region-end (line-end-position)))
           (text (buffer-substring-no-properties text-start text-end))
           (byte-position
            (string-bytes
             (buffer-substring-no-properties text-start position))))
      (when-let* ((nodes (reference-explorer-segmentation--mecab-nodes text))
                  (index
                   (seq-position
                    nodes byte-position
                    (lambda (entry byte)
                      (and (<= (nth 1 entry) byte)
                           (< byte (nth 2 entry)))))))
        (mapcar
         (lambda (bounds)
           (cons (+ text-start
                    (reference-explorer-segmentation--byte-offset-to-character
                     text (car bounds)))
                 (+ text-start
                    (reference-explorer-segmentation--byte-offset-to-character
                     text (cdr bounds)))))
         (reference-explorer-segmentation--compound-bound-candidates nodes index))))))

(defun reference-explorer-segmentation-emacs-backend
    (_position &optional _region-start _region-end)
  "Return ordinary Emacs symbol and word bounds at point."
  (let ((bounds (delq nil (list (bounds-of-thing-at-point 'symbol)
                                (bounds-of-thing-at-point 'word)))))
    (sort (delete-dups bounds)
          (lambda (left right)
            (> (- (cdr left) (car left))
               (- (cdr right) (car right)))))))

(defun reference-explorer-segmentation--run-backends
    (position region-start region-end)
  "Return the first phrase bounds produced for POSITION."
  (seq-some
   (lambda (backend)
     (funcall backend position region-start region-end))
   reference-explorer-segmentation-backends))

(defun reference-explorer-segmentation-word-bound-candidates-at-point (&optional position)
  "Return word-bound candidates containing POSITION or point.
Candidates are ordered from longest to shortest.  Hidden Org-link syntax is
mapped onto its visible description before candidates are collected."
  (pcase-let* ((`(,visible-position ,visible-start ,visible-end)
                (reference-explorer-segmentation--org-visible-context
                 (or position (point)))))
    (save-excursion
      (goto-char visible-position)
      (reference-explorer-segmentation--run-backends
       (point) visible-start visible-end))))

(defun reference-explorer-segmentation-word-bounds-at-point (&optional position)
  "Return the bounds of the word at POSITION or point.
Hidden Org-link syntax is first mapped onto the visible description.  Japanese
words use MeCab segmentation when possible, then fall back to Emacs word
semantics."
  (car (reference-explorer-segmentation-word-bound-candidates-at-point position)))

(defun reference-explorer-segmentation-word-candidates-at-point (&optional position)
  "Return word candidates containing POSITION or point, longest first."
  (mapcar (lambda (bounds)
            (buffer-substring-no-properties (car bounds) (cdr bounds)))
          (reference-explorer-segmentation-word-bound-candidates-at-point position)))

(defun reference-explorer-segmentation-word-at-point (&optional position)
  "Return the word at POSITION or point without text properties."
  (when-let ((bounds (reference-explorer-segmentation-word-bounds-at-point position)))
    (buffer-substring-no-properties (car bounds) (cdr bounds))))

(provide 'reference-explorer-segmentation)
;;; reference-explorer-segmentation.el ends here
