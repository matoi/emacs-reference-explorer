;;; reference-explorer-docset-manager.el --- Install and update docsets -*- lexical-binding: t -*-

;;; Commentary:

;; Network and mutation operations for `reference-explorer-docset'.  The search backend
;; remains entirely local.  Specs are explicit:
;;
;;   Ruby@3.3.*       newest feed entry in the explicitly named 3.3 series
;;   Python@3.12.6    exact feed entry
;;   JavaScript@latest current version declared by the feed

;; A missing `@SELECTOR' is accepted as an alias for `@latest'.

;;; Code:

(require 'cl-lib)
(require 'dom)
(require 'json)
(require 'mm-decode)
(require 'reference-explorer-docset)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'url-util)

(defgroup reference-explorer-docset-manager nil
  "Install and update Dash-compatible docsets."
  :group 'reference-explorer-docset)

(defcustom reference-explorer-docset-manager-feed-base-url
  "https://raw.githubusercontent.com/Kapeli/feeds/master/"
  "Base URL containing official FEED.xml files."
  :type 'string
  :group 'reference-explorer-docset-manager)

(defcustom reference-explorer-docset-manager-version-base-url
  "https://tokyo.kapeli.com/feeds/zzz/versions/"
  "Base URL containing archived official docset versions."
  :type 'string
  :group 'reference-explorer-docset-manager)

(defcustom reference-explorer-docset-manager-feed-list-url
  "https://api.github.com/repos/Kapeli/feeds/git/trees/master?recursive=1"
  "JSON endpoint used to discover official docset feed identifiers."
  :type 'string
  :group 'reference-explorer-docset-manager)

(defcustom reference-explorer-docset-manager-install-directory
  (expand-file-name "docsets" (or (getenv "XDG_DATA_HOME")
                                   "~/.local/share"))
  "Directory containing managed docset installations."
  :type 'directory
  :group 'reference-explorer-docset-manager)

(defcustom reference-explorer-docset-manager-fetch-string-function
  #'reference-explorer-docset-manager--fetch-string
  "Function used to synchronously retrieve a textual URL."
  :type 'function
  :group 'reference-explorer-docset-manager)

(defcustom reference-explorer-docset-manager-download-function
  #'reference-explorer-docset-manager--download
  "Function used to download URL to a destination file."
  :type 'function
  :group 'reference-explorer-docset-manager)

(cl-defstruct (reference-explorer-docset-spec
               (:constructor reference-explorer-docset-spec-create))
  "A requested docset feed and version-selection policy."
  feed policy selector)

(cl-defstruct (reference-explorer-docset-release
               (:constructor reference-explorer-docset-release-create))
  "A resolved docset release."
  spec version url)

(defvar reference-explorer-docset-manager--feed-cache :uninitialized
  "Cached official feed identifiers.")

(defvar reference-explorer-docset-manager--network-description nil
  "Human-readable description for the current network operation.")

(defun reference-explorer-docset-manager--call-with-network-status
    (description function)
  "Call FUNCTION after reporting network DESCRIPTION once."
  (message "%s…" description)
  (funcall function))

(defun reference-explorer-docset-manager--format-byte-size (bytes)
  "Return BYTES as a compact human-readable size."
  (cond
   ((>= bytes (* 1024 1024)) (format "%.1f MiB" (/ bytes 1048576.0)))
   ((>= bytes 1024) (format "%.1f KiB" (/ bytes 1024.0)))
   (t (format "%d bytes" bytes))))

(defun reference-explorer-docset-manager-parse-spec (text)
  "Parse docset specification TEXT into a `reference-explorer-docset-spec'."
  (unless (string-match
           "\\`\\([[:alnum:]_.+-]+\\)\\(?:@\\([[:alnum:]_.+*-]+\\)\\)?\\'"
           (string-trim text))
    (user-error "Invalid docset specification: %s" text))
  (let* ((feed (match-string 1 (string-trim text)))
         (selector (or (match-string 2 (string-trim text)) "latest"))
         policy value)
    (cond
     ((equal selector "latest")
      (setq policy 'latest value nil))
     ((string-suffix-p ".*" selector)
      (setq policy 'series
            value (string-remove-suffix ".*" selector))
      (when (or (string-empty-p value) (string-match-p "\\*" value))
        (user-error "Invalid docset series selector: %s" selector)))
     ((string-match-p "\\*" selector)
      (user-error "A docset wildcard is only valid as a final .*: %s"
                  selector))
     (t
      (setq policy 'exact value selector)))
    (reference-explorer-docset-spec-create
     :feed feed :policy policy :selector value)))

(defun reference-explorer-docset-manager-spec-string (spec)
  "Return canonical selector string for SPEC."
  (format "%s@%s"
          (reference-explorer-docset-spec-feed spec)
          (pcase (reference-explorer-docset-spec-policy spec)
            ('latest "latest")
            ('series (concat (reference-explorer-docset-spec-selector spec) ".*"))
            ('exact (reference-explorer-docset-spec-selector spec)))))

(defun reference-explorer-docset-manager--path-component (text)
  "Return TEXT encoded as one safe path component."
  (if (string-match-p "\\`[[:alnum:]_.+-]+\\'" text)
      text
    (url-hexify-string text)))

(defun reference-explorer-docset-manager--release-name (release)
  "Return versioned bundle name for RELEASE, without `.docset'."
  (let ((spec (reference-explorer-docset-release-spec release)))
    (format "%s-%s"
            (reference-explorer-docset-manager--path-component
             (reference-explorer-docset-spec-feed spec))
            (reference-explorer-docset-manager--path-component
             (reference-explorer-docset-release-version release)))))

(defun reference-explorer-docset-manager--release-target (release install-root)
  "Return RELEASE's unique bundle path below INSTALL-ROOT."
  (let* ((spec (reference-explorer-docset-release-spec release))
         (feed (reference-explorer-docset-manager--path-component
                (reference-explorer-docset-spec-feed spec))))
    (expand-file-name
     (concat (reference-explorer-docset-manager--release-name release) ".docset")
     (expand-file-name feed install-root))))

(defun reference-explorer-docset-manager--fetch-string (url)
  "Synchronously retrieve URL and return its response body."
  (let* ((url-show-status nil)
         (buffer
          (reference-explorer-docset-manager--call-with-network-status
           (or reference-explorer-docset-manager--network-description
               "Retrieving docset metadata")
           (lambda () (url-retrieve-synchronously url t t 30)))))
    (unless buffer
      (error "Failed to retrieve docset feed: %s" url))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (error "Malformed HTTP response for %s" url))
          (buffer-substring-no-properties (point) (point-max)))
      (kill-buffer buffer))))

(defun reference-explorer-docset-manager--download (url destination)
  "Download URL to DESTINATION, replacing a temporary destination only."
  (let ((url-show-status nil)
        (description
         (or reference-explorer-docset-manager--network-description
             "Downloading docset archive")))
    (reference-explorer-docset-manager--call-with-network-status
     description
     (lambda () (url-copy-file url destination t)))
    (message "%s: download complete (%s)"
             description
             (reference-explorer-docset-manager--format-byte-size
              (file-attribute-size (file-attributes destination))))))

(defun reference-explorer-docset-manager--save-response (destination)
  "Save the current URL response body to DESTINATION."
  (goto-char (point-min))
  (let ((handle (mm-dissect-buffer t)))
    (unwind-protect
        (let ((mm-attachment-file-modes (default-file-modes)))
          (mm-save-part-to-file handle destination))
      (mm-destroy-parts handle))))

(defun reference-explorer-docset-manager--download-async-callback
    (status destination on-success on-error)
  "Finish an asynchronous download according to STATUS.
Save it to DESTINATION, then call ON-SUCCESS or ON-ERROR."
  (let ((response-buffer (current-buffer)))
    (unwind-protect
        (condition-case error-data
            (if-let ((network-error (plist-get status :error)))
                (funcall on-error network-error)
              (reference-explorer-docset-manager--save-response destination)
              (funcall on-success))
          (error (funcall on-error error-data)))
      (when (buffer-live-p response-buffer)
        (kill-buffer response-buffer)))))

(defun reference-explorer-docset-manager--download-async
    (url destination on-success on-error)
  "Download URL to DESTINATION without blocking Emacs.
Call ON-SUCCESS without arguments, or ON-ERROR with the error data."
  (let ((url-show-status nil))
    (url-retrieve
     url #'reference-explorer-docset-manager--download-async-callback
     (list destination on-success on-error) t t)))

(defun reference-explorer-docset-manager--feed-url (feed)
  "Return official XML feed URL for FEED."
  (concat (file-name-as-directory reference-explorer-docset-manager-feed-base-url)
          (url-hexify-string feed) ".xml"))

(defun reference-explorer-docset-manager--xml (feed)
  "Retrieve and parse the XML document for FEED."
  (with-temp-buffer
    (let ((reference-explorer-docset-manager--network-description
           (format "Docset %s: retrieving available versions" feed)))
      (insert (funcall reference-explorer-docset-manager-fetch-string-function
                       (reference-explorer-docset-manager--feed-url feed))))
    (libxml-parse-xml-region (point-min) (point-max))))

(defun reference-explorer-docset-manager--node-texts (document tag)
  "Return trimmed text of every TAG node in DOCUMENT."
  (delq nil
        (mapcar (lambda (node)
                  (let ((text (string-trim (or (dom-texts node) ""))))
                    (unless (string-empty-p text) text)))
                (dom-by-tag document tag))))

(defun reference-explorer-docset-manager--feed-data (feed)
  "Return (CURRENT URLS VERSIONS) parsed from FEED."
  (let* ((document (reference-explorer-docset-manager--xml feed))
         (versions (reference-explorer-docset-manager--node-texts document 'version))
         (current (car versions))
         (urls (reference-explorer-docset-manager--node-texts document 'url)))
    (unless (and current urls)
      (error "Docset feed lacks a version or archive URL: %s" feed))
    (list current urls (delete-dups versions))))

(defun reference-explorer-docset-manager-list-feeds (&optional refresh)
  "Return official feed identifiers, refreshing when REFRESH is non-nil."
  (interactive "P")
  (when (or refresh
            (eq reference-explorer-docset-manager--feed-cache :uninitialized))
    (let* ((response
            (let ((reference-explorer-docset-manager--network-description
                   "Retrieving the official docset list"))
              (funcall reference-explorer-docset-manager-fetch-string-function
                       reference-explorer-docset-manager-feed-list-url)))
           (document
            (json-parse-string response :object-type 'alist :array-type 'list))
           (tree (alist-get 'tree document))
           feeds)
      (dolist (entry tree)
        (when-let ((path (alist-get 'path entry)))
          (when (and (equal (alist-get 'type entry) "blob")
                     (not (string-match-p "/" path))
                     (string-suffix-p ".xml" path))
            (push (string-remove-suffix ".xml" path) feeds))))
      (setq reference-explorer-docset-manager--feed-cache
            (sort (delete-dups feeds) #'string-lessp))))
  (when (called-interactively-p 'interactive)
    (message "%d official docset feeds"
             (length reference-explorer-docset-manager--feed-cache)))
  reference-explorer-docset-manager--feed-cache)

(defun reference-explorer-docset-manager--safe-selector-p (selector)
  "Return non-nil when SELECTOR is safe in a specification and path."
  (string-match-p "\\`[[:alnum:]_.+*-]+\\'" selector))

(defun reference-explorer-docset-manager--series-selectors (version)
  "Return explicit wildcard series selectors derivable from VERSION."
  (when (reference-explorer-docset-manager--safe-selector-p version)
    (let ((parts (split-string version "\\." t)))
      (cl-loop for count from 1 below (length parts)
               collect
               (concat (string-join (seq-take parts count) ".") ".*")))))

(defun reference-explorer-docset-manager--selector-candidates (feed-data)
  "Return (CANDIDATES . ANNOTATIONS) derived from FEED-DATA."
  (pcase-let ((`(,current ,_urls ,versions) feed-data))
    (let ((annotations (make-hash-table :test #'equal))
          series exact)
      (puthash "latest" (format "  current → %s" current) annotations)
      (dolist (version versions)
        (when (reference-explorer-docset-manager--safe-selector-p version)
          (push version exact)
          (puthash version "  exact" annotations))
        (dolist (selector
                 (reference-explorer-docset-manager--series-selectors version))
          (unless (gethash selector annotations)
            (push selector series)
            ;; VERSIONS is in provider order, so the first occurrence is the
            ;; version that this series selector will resolve to.
            (puthash selector (format "  series → %s" version)
                     annotations))))
      (cons (append (list "latest") (nreverse series) (nreverse exact))
            annotations))))

(defun reference-explorer-docset-manager-read-spec ()
  "Read a feed and version policy through a two-stage completion UI."
  (let* ((feed
          (completing-read "Docset: "
                           (reference-explorer-docset-manager-list-feeds) nil t))
         (selection-data
          (reference-explorer-docset-manager--selector-candidates
           (reference-explorer-docset-manager--feed-data feed)))
         (candidates (car selection-data))
         (annotations (cdr selection-data))
         (completion-extra-properties
          `(:annotation-function
            ,(lambda (candidate) (gethash candidate annotations))))
         (selector
          (completing-read (format "%s version: " feed)
                           candidates nil t nil nil "latest")))
    (format "%s@%s" feed selector)))

(defun reference-explorer-docset-manager--series-match-p (version series)
  "Return non-nil when VERSION belongs to explicitly selected SERIES."
  (or (equal version series)
      (string-prefix-p (concat series ".") version)))

(defun reference-explorer-docset-manager--archived-url (feed version)
  "Return archive URL for exact FEED VERSION."
  (concat (file-name-as-directory reference-explorer-docset-manager-version-base-url)
          (url-hexify-string feed) "/"
          (url-hexify-string version) "/"
          (url-hexify-string feed) ".tgz"))

(defun reference-explorer-docset-manager-resolve (spec)
  "Resolve SPEC against its feed and return a release."
  (pcase-let* ((`(,current ,urls ,versions)
                (reference-explorer-docset-manager--feed-data
                 (reference-explorer-docset-spec-feed spec)))
               (policy (reference-explorer-docset-spec-policy spec))
               (selector (reference-explorer-docset-spec-selector spec))
               (version
                (pcase policy
                  ('latest current)
                  ('exact (and (member selector versions) selector))
                  ('series
                   (seq-find
                    (lambda (candidate)
                      (reference-explorer-docset-manager--series-match-p
                       candidate selector))
                    versions)))))
    (unless version
      (user-error "No %s version matches %s in %s"
                  policy selector (reference-explorer-docset-spec-feed spec)))
    (reference-explorer-docset-release-create
     :spec spec
     :version version
     :url (if (or (eq policy 'latest) (equal version current))
              (car urls)
            (reference-explorer-docset-manager--archived-url
             (reference-explorer-docset-spec-feed spec) version)))))

;;;###autoload
(defun reference-explorer-docset-manager-list-versions (feed)
  "Display versions published by docset FEED in provider order."
  (interactive "sDocset feed: ")
  (let ((versions (nth 2 (reference-explorer-docset-manager--feed-data feed))))
    (when (called-interactively-p 'interactive)
      (with-output-to-temp-buffer "*Docset Versions*"
        (princ (format "%s versions\n\n" feed))
        (dolist (version versions) (princ version) (terpri))))
    versions))

(defun reference-explorer-docset-manager-read-manifest (file)
  "Read docset specifications from FILE, one per non-comment line."
  (with-temp-buffer
    (insert-file-contents file)
    (cl-loop for line in (split-string (buffer-string) "\n")
             for stripped = (string-trim
                             (replace-regexp-in-string
                              "[[:space:]]*#.*\\'" "" line))
             unless (string-empty-p stripped)
             collect (reference-explorer-docset-manager-parse-spec stripped))))

(defun reference-explorer-docset-manager--safe-archive-entry-p (entry)
  "Return non-nil when archive ENTRY cannot escape its extraction root."
  (and (not (file-name-absolute-p entry))
       (not (member ".." (split-string entry "/" t)))))

(defun reference-explorer-docset-manager--tar-entries (archive)
  "Return file names contained in compressed tar ARCHIVE."
  (with-temp-buffer
    (unless (zerop (process-file "tar" nil t nil "-tzf" archive))
      (error "Cannot list docset archive: %s" archive))
    (split-string (buffer-string) "\n" t)))

(defun reference-explorer-docset-manager--extract (archive directory)
  "Safely extract ARCHIVE into DIRECTORY."
  (let ((entries (reference-explorer-docset-manager--tar-entries archive)))
    (unless (and entries
                 (seq-every-p
                  #'reference-explorer-docset-manager--safe-archive-entry-p entries))
      (error "Docset archive contains an unsafe path"))
    (with-temp-buffer
      (unless (zerop (process-file "tar" nil t nil
                                   "-xzf" archive "-C" directory))
        (error "Cannot extract docset archive: %s" archive)))))

(defun reference-explorer-docset-manager--find-bundle (directory)
  "Return the single valid docset bundle below DIRECTORY."
  (let ((bundles
         (delq nil
               (mapcar #'reference-explorer-docset--bundle
                       (directory-files-recursively
                        directory "\\.docset\\'" t
                        (lambda (subdirectory)
                          (not (string-suffix-p
                                ".docset"
                                (directory-file-name subdirectory)))))))))
    (unless (= (length bundles) 1)
      (error "Expected one valid docset bundle, found %d" (length bundles)))
    (reference-explorer-docset-root (car bundles))))

(defun reference-explorer-docset-manager--write-metadata (file release archive)
  "Write RELEASE and ARCHIVE identity metadata to FILE."
  (let* ((spec (reference-explorer-docset-release-spec release))
         (json-encoding-pretty-print t)
         (data
          `((feed . ,(reference-explorer-docset-spec-feed spec))
            (version . ,(reference-explorer-docset-release-version release))
            (archive_url . ,(reference-explorer-docset-release-url release))
            (sha256 . ,(secure-hash 'sha256 archive))
            (installed_at . ,(format-time-string "%FT%T%z")))))
    (with-temp-file file
      (insert (json-encode data) "\n"))))

(defun reference-explorer-docset-manager--replace-directory (source target)
  "Atomically replace TARGET directory with SOURCE, restoring on failure."
  (let ((backup (concat target ".backup-" (format-time-string "%s%N")))
        replaced)
    (unwind-protect
        (progn
          (when (file-exists-p target)
            (rename-file target backup))
          (condition-case error-data
              (progn
                (rename-file source target)
                (setq replaced t))
            (error
             (when (file-exists-p backup)
               (rename-file backup target))
             (signal (car error-data) (cdr error-data))))
          (when (file-exists-p backup)
            (delete-directory backup t)))
      (unless replaced
        (when (and (file-exists-p backup) (not (file-exists-p target)))
          (rename-file backup target))))))

(defun reference-explorer-docset-manager--cleanup-install (archive stage)
  "Remove temporary ARCHIVE and STAGE paths."
  (when (file-exists-p archive) (delete-file archive))
  (when (file-directory-p stage) (delete-directory stage t)))

(defun reference-explorer-docset-manager--finish-install
    (release name archive stage target)
  "Install downloaded ARCHIVE for RELEASE as NAME at TARGET."
  (let ((extracted (expand-file-name "extracted" stage))
        (ready (expand-file-name (concat name ".docset") stage)))
    (unwind-protect
        (progn
          (make-directory extracted)
          (reference-explorer-docset-manager--extract archive extracted)
          (let ((bundle (reference-explorer-docset-manager--find-bundle extracted)))
            (rename-file bundle ready)
            (reference-explorer-docset-manager--write-metadata
             (expand-file-name reference-explorer-docset-metadata-file-name ready)
             release archive)
            (reference-explorer-docset-manager--replace-directory ready target))
          (reference-explorer-docset-discover t)
          (message "Installed docset %s (%s)"
                   name (reference-explorer-docset-release-version release))
          name)
      (reference-explorer-docset-manager--cleanup-install archive stage))))

(defun reference-explorer-docset-manager--report-install-error
    (name archive stage error-data)
  "Clean up a failed NAME install and report ERROR-DATA."
  (reference-explorer-docset-manager--cleanup-install archive stage)
  (message "Docset %s installation failed: %s"
           name (error-message-string error-data)))

;;;###autoload
(defun reference-explorer-docset-manager-install
    (spec-text &optional update asynchronous)
  "Ensure SPEC-TEXT is installed; replace it when UPDATE is non-nil.
When ASYNCHRONOUS is non-nil, download the archive in the background."
  (interactive (list (reference-explorer-docset-manager-read-spec)
                     current-prefix-arg t))
  (let* ((spec (reference-explorer-docset-manager-parse-spec spec-text))
         (install-root
          (file-name-as-directory reference-explorer-docset-manager-install-directory)))
    (make-directory install-root t)
    (let* ((release (reference-explorer-docset-manager-resolve spec))
           (name (reference-explorer-docset-manager--release-name release))
           (target
            (reference-explorer-docset-manager--release-target release install-root)))
      (make-directory (file-name-directory target) t)
      (if (and (file-directory-p target) (not update))
          (progn (message "Docset already installed: %s" name) name)
        (let* ((description
                (format "Docset %s → %s"
                        (reference-explorer-docset-manager-spec-string spec)
                        (reference-explorer-docset-release-version release)))
               (archive (make-temp-file "reference-explorer-docset-" nil ".tgz"))
               (stage (make-temp-file
                       (expand-file-name ".stage-" install-root) t)))
          (if asynchronous
              (progn
                (message "%s: downloading in the background…" description)
                (reference-explorer-docset-manager--download-async
                 (reference-explorer-docset-release-url release) archive
                 (lambda ()
                   (condition-case error-data
                       (reference-explorer-docset-manager--finish-install
                        release name archive stage target)
                     (error
                      (reference-explorer-docset-manager--report-install-error
                       name archive stage error-data))))
                 (lambda (error-data)
                   (reference-explorer-docset-manager--report-install-error
                    name archive stage error-data)))
                name)
            (let ((reference-explorer-docset-manager--network-description
                   (concat description ": downloading archive")))
              (funcall reference-explorer-docset-manager-download-function
                       (reference-explorer-docset-release-url release) archive))
            (reference-explorer-docset-manager--finish-install
             release name archive stage target)))))))

;;;###autoload
(defun reference-explorer-docset-manager-update (spec-text)
  "Update installed SPEC-TEXT according to its explicit policy."
  (interactive (list (read-string "Docset specification: ")))
  (reference-explorer-docset-manager-install
   spec-text t (called-interactively-p 'interactive)))

(defun reference-explorer-docset-manager-ensure-manifest (file &optional update)
  "Ensure every specification in manifest FILE, updating with UPDATE."
  (dolist (spec (reference-explorer-docset-manager-read-manifest file))
    (reference-explorer-docset-manager-install
     (reference-explorer-docset-manager-spec-string spec)
     update)))

(defun reference-explorer-docset-manager-batch ()
  "Apply the manifest and action supplied by the setup shell adapter."
  (let ((manifest (getenv "REFERENCE_DOCSET_MANIFEST"))
        (action (getenv "REFERENCE_DOCSET_ACTION")))
    (unless (and manifest (file-readable-p manifest))
      (error "REFERENCE_DOCSET_MANIFEST is missing or unreadable"))
    (unless (member action '("ensure" "update"))
      (error "REFERENCE_DOCSET_ACTION must be ensure or update"))
    (reference-explorer-docset-manager-ensure-manifest
     manifest (equal action "update"))))

(provide 'reference-explorer-docset-manager)
;;; reference-explorer-docset-manager.el ends here
