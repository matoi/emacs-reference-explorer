;;; reference-explorer-query-segment.el --- Pluggable phrase selection -*- lexical-binding: t -*-

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

(defgroup reference-explorer-query-segment nil
  "Phrase selection for Reference Explorer."
  :group 'editing)

(defcustom reference-explorer-query-segment-mecab-program "mecab"
  "MeCab executable used to identify Japanese words.
When it is unavailable, word recognition falls back to Emacs."
  :type 'string
  :group 'reference-explorer-query-segment)

(defcustom reference-explorer-query-segment-mecab-initial-minimum-length 2
  "Minimum character length of the preferred initial MeCab phrase.
Among candidates at least this long, the shortest one is preferred for the
initial query.  When no candidate reaches this length, the longest available
candidate is used.  The complete candidate list remains ordered from longest
to shortest so that consumers can expand and shrink the query."
  :type 'natnum
  :group 'reference-explorer-query-segment)

(defcustom reference-explorer-query-segment-backends
  '(reference-explorer-query-segment-mecab-backend
    reference-explorer-query-segment-emacs-backend)
  "Ordered functions used to find phrase bounds at point.
Each function receives POSITION, REGION-START, and REGION-END.  It returns
bounds ordered from the most useful or longest candidate to the shortest, or
nil when it does not handle the text.  REGION-START and REGION-END restrict
selection to visible text, such as an Org link description."
  :type '(repeat function)
  :group 'reference-explorer-query-segment)

(declare-function org-element-context "org-element" (&optional element))
(declare-function org-element-property "org-element"
                  (property node &optional dflt force-undefer))
(declare-function org-element-type "org-element" (element))

(defun reference-explorer-query-segment--org-visible-context (position)
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

(defun reference-explorer-query-segment-visible-position-at-point (&optional position)
  "Return the visible text position represented by POSITION or point.
In an Org descriptive link, hidden markup at either visual edge is mapped
onto the corresponding character in the visible description."
  (car (reference-explorer-query-segment--org-visible-context
        (or position (point)))))

(defun reference-explorer-query-segment--japanese-character-p (character)
  "Return non-nil when CHARACTER belongs to a Japanese writing script."
  (and character (aref (char-category-set character) ?j)))

(defun reference-explorer-query-segment--byte-offset-to-character (string offset)
  "Convert UTF-8 byte OFFSET in STRING to a character offset."
  (length
   (decode-coding-string
    (substring (encode-coding-string string 'utf-8) 0 offset)
    'utf-8)))

(defun reference-explorer-query-segment--mecab-nodes (string)
  "Return MeCab nodes for STRING as (SURFACE START-BYTE END-BYTE FEATURES).
Return nil when MeCab is unavailable or cannot analyze the input."
  (when-let ((program (executable-find reference-explorer-query-segment-mecab-program)))
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

(defun reference-explorer-query-segment--compound-node-p (node)
  "Return non-nil when MeCab NODE can participate in a compound word."
  (let ((part-of-speech (car (nth 3 node))))
    (member part-of-speech '("名詞" "接頭詞"))))

(defun reference-explorer-query-segment--adjacent-nodes-p (left right)
  "Return non-nil when MeCab nodes LEFT and RIGHT have no gap."
  (= (nth 2 left) (nth 1 right)))

(defun reference-explorer-query-segment--compound-bound-candidates (nodes index)
  "Return compound byte bounds in NODES containing node INDEX.
Candidates are ordered from longest to shortest.  Particles, auxiliaries,
punctuation, and whitespace terminate a compound."
  (let ((node (nth index nodes)))
    (if (not (reference-explorer-query-segment--compound-node-p node))
        (list (cons (nth 1 node) (nth 2 node)))
      (let ((first index)
            (last index))
        (while (and (> first 0)
                    (reference-explorer-query-segment--compound-node-p
                     (nth (1- first) nodes))
                    (reference-explorer-query-segment--adjacent-nodes-p
                     (nth (1- first) nodes) (nth first nodes)))
          (setq first (1- first)))
        (while (and (< last (1- (length nodes)))
                    (reference-explorer-query-segment--compound-node-p
                     (nth (1+ last) nodes))
                    (reference-explorer-query-segment--adjacent-nodes-p
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

(defun reference-explorer-query-segment-mecab-backend
    (position &optional region-start region-end)
  "Return MeCab word-bound candidates containing POSITION.
The current logical line is sent to MeCab unless REGION-START and REGION-END
restrict it, as for an Org link description.  Consecutive noun and prefix nodes
form compound candidates ordered from longest to shortest."
  (when (reference-explorer-query-segment--japanese-character-p
         (char-after position))
    (let* ((text-start (or region-start (line-beginning-position)))
           (text-end (or region-end (line-end-position)))
           (text (buffer-substring-no-properties text-start text-end))
           (byte-position
            (string-bytes
             (buffer-substring-no-properties text-start position))))
      (when-let* ((nodes (reference-explorer-query-segment--mecab-nodes text))
                  (index
                   (seq-position
                    nodes byte-position
                    (lambda (entry byte)
                      (and (<= (nth 1 entry) byte)
                           (< byte (nth 2 entry)))))))
        (mapcar
         (lambda (bounds)
           (cons (+ text-start
                    (reference-explorer-query-segment--byte-offset-to-character
                     text (car bounds)))
                 (+ text-start
                    (reference-explorer-query-segment--byte-offset-to-character
                     text (cdr bounds)))))
         (reference-explorer-query-segment--compound-bound-candidates nodes index))))))

(defun reference-explorer-query-segment-emacs-backend
    (_position &optional _region-start _region-end)
  "Return ordinary Emacs symbol and word bounds at point."
  (let ((bounds (delq nil (list (bounds-of-thing-at-point 'symbol)
                                (bounds-of-thing-at-point 'word)))))
    (sort (delete-dups bounds)
          (lambda (left right)
            (> (- (cdr left) (car left))
               (- (cdr right) (car right)))))))

(defun reference-explorer-query-segment--run-backends-with-owner
    (position region-start region-end)
  "Return the backend and first phrase bounds produced for POSITION.
The result is (BACKEND . BOUNDS), or nil when no backend handles the text."
  (cl-loop for backend in reference-explorer-query-segment-backends
           for bounds = (funcall backend position region-start region-end)
           when bounds return (cons backend bounds)))

(defun reference-explorer-query-segment--bound-length (bounds)
  "Return the character length of BOUNDS."
  (- (cdr bounds) (car bounds)))

(defun reference-explorer-query-segment--mecab-initial-bounds (candidates)
  "Return the preferred initial bounds from MeCab CANDIDATES.
Choose the shortest candidate meeting
`reference-explorer-query-segment-mecab-initial-minimum-length'.  Preserve the
first candidate when no candidate meets that minimum."
  (let ((eligible
         (seq-filter
          (lambda (bounds)
            (>= (reference-explorer-query-segment--bound-length bounds)
                reference-explorer-query-segment-mecab-initial-minimum-length))
          candidates)))
    (if eligible
        (seq-reduce
         (lambda (preferred bounds)
           (if (< (reference-explorer-query-segment--bound-length bounds)
                  (reference-explorer-query-segment--bound-length preferred))
               bounds
             preferred))
         (cdr eligible) (car eligible))
      (car candidates))))

(defun reference-explorer-query-segment--word-bound-result-at-point
    (&optional position)
  "Return the owning backend and word bounds at POSITION or point."
  (pcase-let* ((`(,visible-position ,visible-start ,visible-end)
                (reference-explorer-query-segment--org-visible-context
                 (or position (point)))))
    (save-excursion
      (goto-char visible-position)
      (reference-explorer-query-segment--run-backends-with-owner
       (point) visible-start visible-end))))

(defun reference-explorer-query-segment-word-bound-candidates-at-point (&optional position)
  "Return word-bound candidates containing POSITION or point.
Candidates are ordered from longest to shortest.  Hidden Org-link syntax is
mapped onto its visible description before candidates are collected."
  (cdr (reference-explorer-query-segment--word-bound-result-at-point position)))

(defun reference-explorer-query-segment-word-bounds-at-point (&optional position)
  "Return the bounds of the word at POSITION or point.
Hidden Org-link syntax is first mapped onto the visible description.  Japanese
words use the shortest MeCab candidate meeting the configured initial minimum
length, then fall back to Emacs word semantics."
  (when-let* ((result
               (reference-explorer-query-segment--word-bound-result-at-point
                position))
              (backend (car result))
              (candidates (cdr result)))
    (if (eq backend 'reference-explorer-query-segment-mecab-backend)
        (reference-explorer-query-segment--mecab-initial-bounds candidates)
      (car candidates))))

(defun reference-explorer-query-segment-word-candidates-at-point (&optional position)
  "Return word candidates containing POSITION or point, longest first."
  (mapcar (lambda (bounds)
            (buffer-substring-no-properties (car bounds) (cdr bounds)))
          (reference-explorer-query-segment-word-bound-candidates-at-point position)))

(defun reference-explorer-query-segment-word-at-point (&optional position)
  "Return the word at POSITION or point without text properties."
  (when-let ((bounds (reference-explorer-query-segment-word-bounds-at-point position)))
    (buffer-substring-no-properties (car bounds) (cdr bounds))))

(provide 'reference-explorer-query-segment)
;;; reference-explorer-query-segment.el ends here
