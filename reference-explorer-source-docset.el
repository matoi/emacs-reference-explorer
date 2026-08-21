;;; reference-explorer-source-docset.el --- Search and render Dash docsets -*- lexical-binding: t -*-

;;; Commentary:

;; A small backend for the Dash docset layout documented by Kapeli at
;; https://kapeli.com/docsets.  Dash itself is available from
;; https://kapeli.com/dash.  This is an independent compatible reader and is
;; not affiliated with or endorsed by Kapeli.  It deliberately owns no
;; selection UI: callers receive structured results and can render a selected
;; result with SHR.  Searching is local and uses Emacs's built-in SQLite
;; support, so no shell command is assembled from user input.

;;; Code:

(defconst reference-explorer-source-docset-content-buffer-name "*Docset Reference*"
  "Buffer used for committed docset content.")

(require 'cl-lib)
(require 'dom)
(require 'json)
(require 'reference-explorer-source)
(require 'seq)
(require 'shr)
(require 'sqlite)
(require 'subr-x)
(require 'url-util)

(defgroup reference-explorer-source-docset nil
  "Search locally installed Dash-compatible docsets."
  :group 'applications)

(defcustom reference-explorer-source-docset-directories
  (list (expand-file-name "docsets" (or (getenv "XDG_DATA_HOME")
                                         "~/.local/share"))
        (expand-file-name "~/Library/Application Support/Dash/DocSets")
        (expand-file-name "~/.docsets"))
  "Directories searched recursively for `.docset' bundles.
Missing directories are ignored.  The first bundle with a given identity wins."
  :type '(repeat directory)
  :group 'reference-explorer-source-docset)

(defcustom reference-explorer-source-docset-mode-alist
  '(((ruby-mode ruby-ts-mode) . ("Ruby"))
    ((python-mode python-ts-mode) . ("Python"))
    ((js-mode js-ts-mode typescript-mode typescript-ts-mode tsx-ts-mode)
     . ("JavaScript" "NodeJS"))
    ((c-mode c-ts-mode c++-mode c++-ts-mode) . ("C" "C++")))
  "Preferred docset selectors for major modes.
Each entry has the form (MODE... . DOCSET-SELECTORS).  A mode matches when the
current buffer is derived from any MODE.  Selectors use `Feed', `Feed@latest',
`Feed@3.3.*', or `Feed@3.3.7' syntax and are searched in the listed order.
`Feed' is equivalent to `Feed@latest' among locally installed versions."
  :type '(repeat (cons (repeat symbol) (repeat string)))
  :group 'reference-explorer-source-docset)

(defcustom reference-explorer-source-docset-max-results 80
  "Maximum number of combined results returned by one search."
  :type 'integer
  :group 'reference-explorer-source-docset)

(defcustom reference-explorer-source-docset-warn-when-missing t
  "Warn when a visited file's mode has selectors but no installed docset."
  :type 'boolean
  :group 'reference-explorer-source-docset)

(defcustom reference-explorer-source-docset-code-class-mode-alist
  '(("ruby" . ruby-mode)
    ("python" . python-mode)
    ("py" . python-mode)
    ("javascript" . js-mode)
    ("js" . js-mode)
    ("typescript" . typescript-ts-mode)
    ("c" . c-mode)
    ("cpp" . c++-mode)
    ("c++" . c++-mode))
  "Major modes used to fontify classified docset code blocks.
The key is one CSS class on a `pre' element.  An unclassified block remains
fixed-pitch but is not guessed from the surrounding docset, since reference
pages often mix source code, shell commands, and terminal output."
  :type '(alist :key-type string :value-type function)
  :group 'reference-explorer-source-docset)

(defface reference-explorer-source-docset-code-block
  '((t :inherit fixed-pitch :extend t))
  "Base face for a docset code block.
Syntax faces supplied by the active theme are layered over this face."
  :group 'reference-explorer-source-docset)

(cl-defstruct (reference-explorer-source-docset
               (:constructor reference-explorer-source-docset-create))
  "One installed docset bundle."
  name feed version root database documents)

(cl-defstruct (reference-explorer-source-docset-result
               (:constructor reference-explorer-source-docset-result-create))
  "One search result from a docset."
  name type path docset exact)

(defvar reference-explorer-source-docset--cache :uninitialized
  "Cached installed docsets, or `:uninitialized' before discovery.")

(defvar reference-explorer-source-docset--warned-missing (make-hash-table :test #'equal)
  "Mode and selector combinations already warned about this session.")

(defvar-local reference-explorer-source-docset-current-result nil
  "Result rendered in the current docset buffer.")

(defconst reference-explorer-source-docset-metadata-file-name ".reference-explorer-source-docset.json"
  "Metadata file stored inside a managed docset bundle.")

(defun reference-explorer-source-docset--code-mode (dom)
  "Return the configured major mode for code-block DOM, or nil."
  (let ((classes
         (append
          (split-string (or (dom-attr dom 'class) ""))
          (when-let ((code (car (dom-by-tag dom 'code))))
            (split-string (or (dom-attr code 'class) ""))))))
    (seq-some
     (lambda (class)
       (alist-get (string-remove-prefix "language-" class)
                  reference-explorer-source-docset-code-class-mode-alist nil nil #'equal))
     classes)))

(defun reference-explorer-source-docset--fontify-code-string (text mode)
  "Return TEXT fontified with major MODE.
Return TEXT unchanged when MODE is unavailable or cannot be initialized."
  (if (not (fboundp mode))
      text
    (condition-case nil
        (with-temp-buffer
          (insert text)
          (delay-mode-hooks (funcall mode))
          (font-lock-ensure (point-min) (point-max))
          (buffer-substring (point-min) (point-max)))
      (error text))))

(defun reference-explorer-source-docset--shr-tag-pre (dom)
  "Render code-block DOM with fixed pitch and available syntax colors."
  (let ((start (point)))
    (shr-tag-pre dom)
    (let* ((end (point))
           (mode (reference-explorer-source-docset--code-mode dom)))
      (when mode
        (let ((fontified
               (reference-explorer-source-docset--fontify-code-string
                (buffer-substring-no-properties start end) mode)))
          (delete-region start end)
          (goto-char start)
          (insert fontified)
          (setq end (point))))
      (add-face-text-property
       start end 'reference-explorer-source-docset-code-block t))))

(define-derived-mode reference-explorer-source-docset-mode special-mode "Docset"
  "Major mode for rendered docset articles."
  (setq-local word-wrap t))

(defun reference-explorer-source-docset--metadata (root)
  "Return managed metadata from docset ROOT, or nil."
  (let ((file (expand-file-name reference-explorer-source-docset-metadata-file-name root)))
    (when (file-regular-p file)
      (condition-case nil
          (json-read-file file)
        (error nil)))))

(defun reference-explorer-source-docset--bundle (root)
  "Return a `reference-explorer-source-docset' for bundle ROOT, or nil when invalid."
  (let* ((database (expand-file-name "Contents/Resources/docSet.dsidx" root))
         (documents (expand-file-name "Contents/Resources/Documents" root))
         (name (string-remove-suffix
                ".docset"
                (file-name-nondirectory (directory-file-name root))))
         (metadata (reference-explorer-source-docset--metadata root))
         (feed (or (alist-get 'feed metadata) name))
         (version (or (alist-get 'version metadata)
                      (alist-get 'resolved_version metadata))))
    (when (and (file-regular-p database) (file-directory-p documents))
      (reference-explorer-source-docset-create
       :name name
       :feed feed
       :version version
       :root root
       :database database
       :documents documents))))

(defun reference-explorer-source-docset-discover (&optional refresh)
  "Return installed docsets, refreshing discovery when REFRESH is non-nil."
  (when (or refresh (eq reference-explorer-source-docset--cache :uninitialized))
    (let ((seen (make-hash-table :test #'equal))
          bundles)
      (dolist (directory reference-explorer-source-docset-directories)
        (when (file-directory-p directory)
          (dolist (root (directory-files-recursively
                         directory "\\.docset\\'" t
                         (lambda (subdirectory)
                           (not (string-suffix-p
                                 ".docset"
                                 (directory-file-name subdirectory))))))
            (when-let ((bundle (and (file-directory-p root)
                                    (reference-explorer-source-docset--bundle root))))
              (let ((identity
                     (if (reference-explorer-source-docset-version bundle)
                         (list 'managed
                               (reference-explorer-source-docset-feed bundle)
                               (reference-explorer-source-docset-version bundle))
                       (list 'unmanaged (reference-explorer-source-docset-name bundle)))))
                (unless (gethash identity seen)
                  (puthash identity t seen)
                  (push bundle bundles)))))))
      (setq reference-explorer-source-docset--cache (nreverse bundles))))
  reference-explorer-source-docset--cache)

(defun reference-explorer-source-docset-refresh ()
  "Refresh installed docset discovery interactively."
  (interactive)
  (let ((count (length (reference-explorer-source-docset-discover t))))
    (message "Discovered %d docset%s" count (if (= count 1) "" "s"))))

(defun reference-explorer-source-docset-names-for-mode (&optional mode)
  "Return configured docset names for MODE or the current major mode."
  (let ((mode (or mode major-mode)))
    (cdr
     (seq-find
      (lambda (entry)
        (seq-some (lambda (parent)
                    (or (eq mode parent)
                        (provided-mode-derived-p mode parent)))
                  (car entry)))
      reference-explorer-source-docset-mode-alist))))

(defun reference-explorer-source-docset--parse-selector (text)
  "Parse local docset selector TEXT as (FEED POLICY VALUE)."
  (unless (string-match
           "\\`\\([[:alnum:]_.+-]+\\)\\(?:@\\([[:alnum:]_.+*-]+\\)\\)?\\'"
           text)
    (user-error "Invalid docset selector: %s" text))
  (let ((feed (match-string 1 text))
        (selector (or (match-string 2 text) "latest")))
    (cond
     ((equal selector "latest") (list feed 'latest nil))
     ((and (string-suffix-p ".*" selector)
           (not (string-match-p "\\*" (string-remove-suffix ".*" selector))))
      (list feed 'series (string-remove-suffix ".*" selector)))
     ((string-match-p "\\*" selector)
      (user-error "A docset wildcard is only valid as a final .*: %s" text))
     (t (list feed 'exact selector)))))

(defun reference-explorer-source-docset--series-match-p (version series)
  "Return non-nil when VERSION belongs to SERIES."
  (and version
       (or (equal version series)
           (string-prefix-p (concat series ".") version))))

(defun reference-explorer-source-docset--newer-p (left right)
  "Return non-nil when docset LEFT is newer than RIGHT."
  (let ((left-version (reference-explorer-source-docset-version left))
        (right-version (reference-explorer-source-docset-version right)))
    (cond
     ((null right-version) (and left-version t))
     ((null left-version) nil)
     (t
      (condition-case nil
          (version< right-version left-version)
        (error (string-lessp right-version left-version)))))))

(defun reference-explorer-source-docset--select-installed (selector installed)
  "Select one docset matching SELECTOR from INSTALLED."
  (pcase-let* ((`(,feed ,policy ,value)
                (reference-explorer-source-docset--parse-selector selector))
               (candidates
                (seq-filter
                 (lambda (docset)
                   (and (equal feed (reference-explorer-source-docset-feed docset))
                        (pcase policy
                          ('latest t)
                          ('series
                           (reference-explorer-source-docset--series-match-p
                            (reference-explorer-source-docset-version docset) value))
                          ('exact
                           (equal value (reference-explorer-source-docset-version docset))))))
                 installed)))
    (seq-reduce
     (lambda (selected candidate)
       (if (or (null selected)
               (reference-explorer-source-docset--newer-p candidate selected))
           candidate
         selected))
     candidates nil)))

(defun reference-explorer-source-docset-for-mode (&optional mode)
  "Return installed docsets selected for MODE, in configured order."
  (let ((installed (reference-explorer-source-docset-discover))
        (seen (make-hash-table :test #'equal))
        selected)
    (dolist (selector (reference-explorer-source-docset-names-for-mode mode))
      (when-let ((docset
                  (reference-explorer-source-docset--select-installed selector installed)))
        (unless (gethash (reference-explorer-source-docset-root docset) seen)
          (puthash (reference-explorer-source-docset-root docset) t seen)
          (push docset selected))))
    (nreverse selected)))

(defun reference-explorer-source-docset-available-p (&optional mode)
  "Return non-nil when MODE has at least one installed configured docset."
  (and (sqlite-available-p) (reference-explorer-source-docset-for-mode mode)))

(defun reference-explorer-source-docset-warn-if-missing ()
  "Warn once when the current visited file has no configured docset match."
  (when-let* ((reference-explorer-source-docset-warn-when-missing)
              (buffer-file-name)
              (selectors (reference-explorer-source-docset-names-for-mode major-mode))
              ((null (reference-explorer-source-docset-for-mode major-mode)))
              (key selectors)
              ((not (gethash key reference-explorer-source-docset--warned-missing))))
    (puthash key t reference-explorer-source-docset--warned-missing)
    (display-warning
     'reference-explorer-source-docset
     (format
      (concat "No installed docset matches %s for %s; "
              "use M-x reference-explorer-source-docset-manager-install to add one, "
              "or H-. will use its next provider")
      (string-join selectors ", ") major-mode)
     :warning)))

(add-hook 'find-file-hook #'reference-explorer-source-docset-warn-if-missing)

(defun reference-explorer-source-docset--escape-like (text)
  "Escape SQLite LIKE metacharacters in TEXT."
  (replace-regexp-in-string
   "[_%\\\\]" (lambda (match) (concat "\\" match)) text t t))

(defconst reference-explorer-source-docset--member-separators '("." "#" "::" "/")
  "Separators preceding an unqualified member name in docset indexes.")

(defun reference-explorer-source-docset--normalize-index-path (path)
  "Remove Dash metadata prefixes from indexed PATH."
  (replace-regexp-in-string "\\`<[^>]+>" "" (or path "")))

(defun reference-explorer-source-docset--ranked-match (column query)
  "Return SQL rank, predicate, and parameters for COLUMN matching QUERY.
An exact unqualified member such as `Kernel.require' ranks after a full exact
match but before a heading that merely starts with `require'."
  (let* ((escaped (reference-explorer-source-docset--escape-like query))
         (leaf-exact-patterns
          (mapcar (lambda (separator)
                    (concat "%" separator escaped))
                  reference-explorer-source-docset--member-separators))
         (leaf-prefix-patterns
          (mapcar (lambda (pattern) (concat pattern "%"))
                  leaf-exact-patterns))
         (full-prefix-pattern (concat escaped "%"))
         (exact (format "%s = ? COLLATE NOCASE" column))
         (like (format "%s LIKE ? ESCAPE '\\' COLLATE NOCASE" column))
         (leaf-exact
          (concat "(" (string-join (make-list 4 like) " OR ") ")"))
         (leaf-prefix
          (concat "(" (string-join (make-list 4 like) " OR ") ")"))
         (rank
          (format
           "CASE WHEN %s THEN 0 WHEN %s THEN 1 WHEN %s THEN 2 WHEN %s THEN 3 END"
           exact leaf-exact like leaf-prefix))
         (predicate
          (format "(%s OR %s OR %s OR %s)"
                  exact leaf-exact like leaf-prefix))
         (parameters
          (append (list query)
                  leaf-exact-patterns
                  (list full-prefix-pattern)
                  leaf-prefix-patterns)))
    (list rank predicate (append parameters parameters))))

(defun reference-explorer-source-docset--search-one (docset query limit)
  "Search DOCSET for exact and prefix matches to QUERY, up to LIMIT."
  (let ((database (sqlite-open (reference-explorer-source-docset-database docset))))
    (unwind-protect
        (condition-case nil
            (let* ((dash-p
                    (sqlite-select
                     database
                     (concat
                      "SELECT 1 FROM sqlite_master "
                      "WHERE type = 'table' AND name = 'searchIndex'")))
                   (column (if dash-p "name" "t.ZTOKENNAME"))
                   (match (reference-explorer-source-docset--ranked-match column query))
                   (rank (nth 0 match))
                   (predicate (nth 1 match))
                   (parameters (nth 2 match))
                   (rows
                    (if dash-p
                        (sqlite-select
                         database
                         (format
                          (concat
                           "SELECT name, type, path, NULL, %s AS rank "
                           "FROM searchIndex WHERE %s "
                           "ORDER BY rank, length(name), name COLLATE NOCASE "
                           "LIMIT ?")
                          rank predicate)
                         (append parameters (list limit)))
                      (sqlite-select
                       database
                       (format
                        (concat
                         "SELECT t.ZTOKENNAME, ty.ZTYPENAME, f.ZPATH, "
                         "m.ZANCHOR, %s AS rank FROM ZTOKEN t "
                         "JOIN ZTOKENTYPE ty ON ty.Z_PK = t.ZTOKENTYPE "
                         "JOIN ZTOKENMETAINFORMATION m ON m.ZTOKEN = t.Z_PK "
                         "JOIN ZFILEPATH f ON f.Z_PK = m.ZFILE "
                         "WHERE %s ORDER BY rank, length(t.ZTOKENNAME), "
                         "t.ZTOKENNAME COLLATE NOCASE LIMIT ?")
                        rank predicate)
                       (append parameters (list limit))))))
              (mapcar
               (lambda (row)
                 (reference-explorer-source-docset-result-create
                  :name (nth 0 row)
                  :type (nth 1 row)
                  :path (reference-explorer-source-docset--normalize-index-path
                         (concat (nth 2 row)
                                 (when-let ((anchor (nth 3 row)))
                                   (concat "#" anchor))))
                  :docset docset
                  :exact (<= (nth 4 row) 1)))
               rows))
          (sqlite-error nil))
      (sqlite-close database))))

(defun reference-explorer-source-docset-search (query &optional mode)
  "Return exact then prefix docset results for QUERY and MODE.
Within each match class, configured docset order is preserved."
  (let ((query (string-trim (or query "")))
        exact prefix)
    (unless (string-empty-p query)
      (catch 'full
        (dolist (docset (reference-explorer-source-docset-for-mode mode))
          (dolist (result
                   (reference-explorer-source-docset--search-one
                    docset query reference-explorer-source-docset-max-results))
            ;; Broken index rows must neither reach the selector nor consume
            ;; one of the available result slots.
            (when (reference-explorer-source-docset-result-file result)
              (push result
                    (if (reference-explorer-source-docset-result-exact result) exact prefix))
              (when (>= (+ (length exact) (length prefix))
                        reference-explorer-source-docset-max-results)
                (throw 'full nil))))))
      (append (nreverse exact) (nreverse prefix)))))

(defun reference-explorer-source-docset-result-file (result)
  "Return RESULT's safe local HTML path, without its fragment."
  (let* ((docset (reference-explorer-source-docset-result-docset result))
         (documents (file-name-as-directory
                     (reference-explorer-source-docset-documents docset)))
         (normalized
          (reference-explorer-source-docset--normalize-index-path
           (reference-explorer-source-docset-result-path result)))
         (raw-path (car (split-string normalized "#")))
         (decoded (url-unhex-string raw-path))
         (file (expand-file-name decoded documents)))
    (when (and (file-regular-p file) (file-in-directory-p file documents))
      file)))

(defun reference-explorer-source-docset-result-fragment (result)
  "Return RESULT's decoded page fragment, or nil."
  (when-let ((fragment
              (cadr (split-string
                     (reference-explorer-source-docset--normalize-index-path
                      (reference-explorer-source-docset-result-path result))
                     "#"))))
    (url-unhex-string fragment)))

(defun reference-explorer-source-docset--fragment-identifiers (result)
  "Return raw and decoded fragment identifiers for RESULT."
  (when-let ((raw
              (cadr (split-string
                     (reference-explorer-source-docset--normalize-index-path
                      (reference-explorer-source-docset-result-path result))
                     "#"))))
    (delete-dups (list raw (url-unhex-string raw)))))

(defun reference-explorer-source-docset-result-url (result)
  "Return a local file URL for RESULT."
  (when-let ((file (reference-explorer-source-docset-result-file result)))
    (concat (url-encode-url (concat "file://" file))
            (when-let ((fragment (reference-explorer-source-docset-result-fragment result)))
              (concat "#" (url-hexify-string fragment))))))

(defun reference-explorer-source-docset--dom-class-p (node class)
  "Return non-nil when DOM NODE has CSS CLASS."
  (and (consp node)
       (member class (split-string (or (dom-attr node 'class) "")))))

(defun reference-explorer-source-docset--dom-find (node predicate &optional parent)
  "Return (NODE PARENT) below NODE satisfying PREDICATE."
  (when (consp node)
    (if (funcall predicate node)
        (list node parent)
      (cl-loop for child in (dom-children node)
               when (consp child)
               thereis (reference-explorer-source-docset--dom-find child predicate node)))))

(defun reference-explorer-source-docset--dom-identifier-p (node identifiers)
  "Return non-nil when NODE matches one of IDENTIFIERS."
  (seq-some
   (lambda (identifier)
     (or (equal (dom-attr node 'name) identifier)
         (equal (dom-attr node 'id) identifier)))
   identifiers))

(defun reference-explorer-source-docset--heading-level (node)
  "Return heading level of DOM NODE, or nil."
  (and (consp node)
       (memq (dom-tag node) '(h1 h2 h3 h4 h5 h6))
       (string-to-number (substring (symbol-name (dom-tag node)) 1))))

(defun reference-explorer-source-docset--dom-section-from-match (match)
  "Return the entry section represented by DOM MATCH.
MATCH is the (NODE PARENT) pair returned by `reference-explorer-source-docset--dom-find'."
  (pcase-let* ((`(,node ,parent) match)
               (dash-anchor-p
                (reference-explorer-source-docset--dom-class-p node "dashAnchor"))
               (method-detail-p
                (reference-explorer-source-docset--dom-class-p node "method-detail")))
    (cond
     (method-detail-p node)
     ((null parent) node)
     (t
      (let* ((siblings (dom-children parent))
             (tail (memq node siblings))
             (nodes (if dash-anchor-p (cdr tail) tail))
             (initial-level
              (and (not dash-anchor-p)
                   (reference-explorer-source-docset--heading-level node)))
             collected done)
        (dolist (sibling nodes)
          (unless done
            (let ((level (reference-explorer-source-docset--heading-level sibling)))
              (if (and collected
                       (or (reference-explorer-source-docset--dom-class-p
                            sibling "dashAnchor")
                           (and initial-level level
                                (<= level initial-level))))
                  (setq done t)
                (push sibling collected)))))
        (when collected
          `(div ((class . "reference-explorer-source-docset-entry"))
                ,@(nreverse collected))))))))

(defun reference-explorer-source-docset--read-document (file)
  "Parse local HTML FILE into a DOM tree."
  (with-temp-buffer
    (insert-file-contents file)
    (libxml-parse-html-region (point-min) (point-max))))

(defun reference-explorer-source-docset--entry-section (document identifiers)
  "Return DOCUMENT section matching IDENTIFIERS.
When IDENTIFIERS is nil, return the document's main content."
  (if identifiers
      (when-let ((match
                  (reference-explorer-source-docset--dom-find
                   document
                   (lambda (node)
                     (reference-explorer-source-docset--dom-identifier-p node identifiers)))))
        (reference-explorer-source-docset--dom-section-from-match match))
    (let ((content (or (car (dom-by-tag document 'main))
                       (car (dom-by-tag document 'body))
                       document)))
      ;; RDoc puts breadcrumb navigation before the article heading inside
      ;; `main'.  Starting from the first h1 both removes that page chrome and
      ;; gives a no-fragment class/module result the same heading-first shape
      ;; as an anchored method result.
      (if-let ((heading-match
                (reference-explorer-source-docset--dom-find
                 content (lambda (node) (eq (dom-tag node) 'h1)))))
          (reference-explorer-source-docset--dom-section-from-match heading-match)
        content))))

(defun reference-explorer-source-docset--alias-href (section)
  "Return the documented alias target href inside SECTION, or nil."
  (when-let* ((match
              (reference-explorer-source-docset--dom-find
               section
               (lambda (node)
                 (reference-explorer-source-docset--dom-class-p node "aliases"))))
             (link (car (dom-by-tag (car match) 'a))))
    (dom-attr link 'href)))

(defun reference-explorer-source-docset--relative-target (file href documents)
  "Resolve local HREF relative to FILE and safely inside DOCUMENTS.
Return (FILE . FRAGMENT), or nil."
  (when (and href
             (not (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" href)))
    (let* ((parts (split-string href "#"))
           (relative (car parts))
           (fragment (cadr parts))
           (target-file
            (if (string-empty-p relative)
                file
              (expand-file-name (url-unhex-string relative)
                                (file-name-directory file)))))
      (when (and fragment
                 (file-regular-p target-file)
                 (file-in-directory-p target-file documents))
        (cons target-file (url-unhex-string fragment))))))

(defun reference-explorer-source-docset--resolve-alias (section file documents)
  "Append alias target content to SECTION when it points inside DOCUMENTS."
  (if-let* ((href (reference-explorer-source-docset--alias-href section))
            (target (reference-explorer-source-docset--relative-target file href documents))
            (document (reference-explorer-source-docset--read-document (car target)))
            (target-section
             (reference-explorer-source-docset--entry-section document (list (cdr target)))))
      `(div ((class . "reference-explorer-source-docset-alias"))
            ,section
            (hr nil)
            (p ((class . "reference-explorer-source-docset-alias-target"))
               (strong nil "Alias target"))
            ,target-section)
    section))

(defun reference-explorer-source-docset--rdoc-source-node-p (node)
  "Return non-nil when NODE is RDoc's source control or source body."
  (and (consp node)
       (or (reference-explorer-source-docset--dom-class-p node "method-controls")
           (reference-explorer-source-docset--dom-class-p node "method-source-code"))))

(defun reference-explorer-source-docset--normalize-render-order (node)
  "Return NODE with browser-only presentation order normalized for SHR.
RDoc places an expanded method source before its description and relies on
CSS and JavaScript to hide it.  SHR has no such disclosure widget, so keep the
source available but move it after the documentation it would otherwise hide."
  (if (not (consp node))
      node
    (let* ((children
            (mapcar #'reference-explorer-source-docset--normalize-render-order
                    (dom-children node)))
           (rdoc-method-p
            (reference-explorer-source-docset--dom-class-p node "method-detail"))
           (source-nodes
            (and rdoc-method-p
                 (seq-filter #'reference-explorer-source-docset--rdoc-source-node-p
                             children))))
      (when source-nodes
        (setq children
              (append
               (seq-remove #'reference-explorer-source-docset--rdoc-source-node-p children)
               source-nodes)))
      (cons (dom-tag node)
            (cons (dom-attributes node) children)))))

(defun reference-explorer-source-docset--render-data (result)
  "Return (FILE DOCUMENT SECTION) used to render RESULT."
  (unless (reference-explorer-source-docset-result-p result)
    (error "Not a docset result: %S" result))
  (let ((file (reference-explorer-source-docset-result-file result)))
    (unless file
      (user-error "Docset page is missing or unsafe: %s"
                  (reference-explorer-source-docset-result-path result)))
    (let* ((document (reference-explorer-source-docset--read-document file))
           (section
            (reference-explorer-source-docset--entry-section
             document (reference-explorer-source-docset--fragment-identifiers result))))
      (unless section
        (user-error "Docset entry target is missing: %s"
                    (reference-explorer-source-docset-result-path result)))
      (list
       file document
       (reference-explorer-source-docset--normalize-render-order
        (reference-explorer-source-docset--resolve-alias
         section file
         (file-name-as-directory
          (reference-explorer-source-docset-documents
           (reference-explorer-source-docset-result-docset result)))))))))

(defun reference-explorer-source-docset--html-head-assets (document)
  "Return safe presentation nodes copied from DOCUMENT's head.
Stylesheets and inline styles are retained.  Scripts are deliberately omitted:
an installed docset is documentation input, not trusted application code."
  (when-let ((head (car (dom-by-tag document 'head))))
    (cl-loop
     for node in (dom-children head)
     when (and (consp node)
               (or (eq (dom-tag node) 'style)
                   (and (eq (dom-tag node) 'link)
                        (equal (downcase (or (dom-attr node 'rel) ""))
                               "stylesheet"))))
     collect (copy-tree node))))

(defconst reference-explorer-source-docset--entry-style
  (concat
   "html, body { min-width: 0 !important; }\n"
   "body.reference-explorer-source-docset-entry { display: block !important; "
   "margin: 0 !important; padding: 0.8rem !important; }\n"
   "body.reference-explorer-source-docset-entry > main { display: block !important; "
   "width: auto !important; max-width: none !important; "
   "margin: 0 !important; padding: 0 !important; }\n")
  "CSS that removes full-page layout constraints from an extracted entry.")

(defconst reference-explorer-source-docset--entry-script
  (concat
   "document.addEventListener('click', function (event) {"
   "var toggle = event.target.closest('.method-source-toggle');"
   "if (!toggle) return;"
   "var detail = toggle.closest('.method-detail');"
   "var source = null;"
   "if (detail) source = detail.querySelector('.method-source-code');"
   "if (source) source.classList.toggle('active-menu');"
   "});")
  "Minimal source disclosure behavior for extracted RDoc entries.")

(defun reference-explorer-source-docset-render-html (result &optional extra-style)
  "Return a self-contained local HTML document for RESULT.
The selected entry is isolated from the original page while its stylesheets
and relative links continue to resolve against the source document.
Append optional EXTRA-STYLE after the docset's own stylesheets."
  (let* ((data (reference-explorer-source-docset--render-data result))
         (file (nth 0 data))
         (document (nth 1 data))
         (section (nth 2 data))
         (source-body (car (dom-by-tag document 'body)))
         (body-attributes
          (copy-tree (and source-body (dom-attributes source-body))))
         (body-class (alist-get 'class body-attributes))
         (base-url
          (url-encode-url
           (concat "file://"
                   (file-name-as-directory (file-name-directory file))))))
    (setf (alist-get 'class body-attributes)
          (string-join
           (delq nil (list body-class "reference-explorer-source-docset-entry")) " "))
    (let ((html
           `(html nil
             (head nil
              (meta ((charset . "utf-8")))
              (meta ((name . "viewport")
                     (content . "width=device-width, initial-scale=1")))
              (base ((href . ,base-url)))
              ,@(reference-explorer-source-docset--html-head-assets document)
              (style nil ,reference-explorer-source-docset--entry-style)
              ,@(when extra-style `((style nil ,extra-style))))
             (body ,body-attributes
              (main nil ,section)
              (script nil ,reference-explorer-source-docset--entry-script)))))
      (with-temp-buffer
        (dom-print html nil nil)
        (buffer-string)))))

(defun reference-explorer-source-docset-render (result &optional buffer-name)
  "Render RESULT with SHR and return BUFFER-NAME's buffer."
  (pcase-let ((`(,file ,_document ,section)
               (reference-explorer-source-docset--render-data result)))
    (let ((buffer (get-buffer-create (or buffer-name "*Docset Reference*"))))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (shr-width 80)
              (shr-base (url-encode-url
                         (concat "file://"
                                 (file-name-as-directory
                                  (file-name-directory file))))))
          (erase-buffer)
          (let ((shr-external-rendering-functions
                 `((pre . reference-explorer-source-docset--shr-tag-pre)
                   ,@shr-external-rendering-functions)))
            (shr-insert-document section))
          (reference-explorer-source-docset-mode)
          (setq reference-explorer-source-docset-current-result result)
          (goto-char (point-min))
          (skip-chars-forward " \t\r\n")
          (delete-region (point-min) (point))
          (goto-char (point-min))
          (when (string-empty-p (string-trim (buffer-string)))
            (user-error "Docset entry has no content: %s"
                        (reference-explorer-source-docset-result-name result))))
      buffer))))

(defun reference-explorer-source-docset--context-mode (context)
  "Return the originating major mode recorded in CONTEXT."
  (when-let* ((marker (and context (reference-explorer-context-marker context)))
              (buffer (and (markerp marker) (marker-buffer marker))))
    (buffer-local-value 'major-mode buffer)))

(defun reference-explorer-source-docset-protocol-search
    (query context success _failure)
  "Search docsets for QUERY and CONTEXT, then call SUCCESS."
  (funcall success
           (reference-explorer-source-docset-search
            query (reference-explorer-source-docset--context-mode context))))

(defun reference-explorer-source-docset-protocol-annotation (result _context)
  "Return a plain annotation for docset RESULT."
  (let ((feed
         (reference-explorer-source-docset-feed
          (reference-explorer-source-docset-result-docset result)))
        (type (reference-explorer-source-docset-result-type result)))
    (string-join (delq nil (list type feed)) "  ")))

(defun reference-explorer-source-docset-protocol-available-p (context)
  "Return non-nil when docsets can search CONTEXT."
  (and (sqlite-available-p)
       (or (null context)
           (reference-explorer-source-docset-for-mode
            (reference-explorer-source-docset--context-mode context)))))

(reference-explorer-register-source
 'docset
 :title "Dash docsets"
 :search #'reference-explorer-source-docset-protocol-search
 :label #'reference-explorer-source-docset-result-name
 :annotation #'reference-explorer-source-docset-protocol-annotation
 :render #'reference-explorer-source-docset-render
 :available-p #'reference-explorer-source-docset-protocol-available-p
 :provider t
 :provider-function 'reference-explorer-ui-docset-provider-display)

(provide 'reference-explorer-source-docset)
;;; reference-explorer-source-docset.el ends here
