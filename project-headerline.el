;;; project-headerline.el --- Customizable project headerline -*- lexical-binding: t -*-

;; Copyright (C) 2025 Victor Gaydov and contributors
;; Copyright (C) 2020 emacs-lsp maintainers

;; Author: Victor Gaydov <victor@enise.org>
;; Created: 03 Feb 2025
;; URL: https://github.com/gavv/project-headerline
;; Version: 0.4
;; Package-Requires: ((emacs "28.2") (f "0.21.0") (s "1.13.0") (all-the-icons "5.0.0"))
;; Keywords: convenience

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Notice:

;; Several functions were ported from lsp-headerline.el, so the copyrights
;; includes one from that module.

;;; Commentary:

;; project-headerline implements a minor mode that shows a headerline with
;; current project name, and the path to current buffer from the project root.

;; It is inspired by lsp-headerline, but it doesn't show symbol and diagnostic
;; information, has no dependency on lsp, and can be used for buffers of any kind.

;; Please refer to README.org and docstrings for further details.

;;; Code:

(require 'dired-aux)
(require 'project)
(require 'seq)
(require 'vc)

(require 'projectile nil 'noerror)
(require 'magit nil 'noerror)
(require 'all-the-icons nil 'noerror)

(require 'f)
(require 's)

(defgroup project-headerline nil
  "Customizable project headerline."
  :prefix "project-headerline-"
  :group 'convenience
  :link '(url-link "https://github.com/gavv/project-headerline"))

(defface project-headerline-project-name
  '((t :inherit font-lock-string-face :weight bold))
  "Face used for \\='project-name segment."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline)

(defface project-headerline-path-in-project
  '((t :inherit font-lock-keyword-face))
  "Face used for \\='path-in-project segment."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline)

(defface project-headerline-buffer-name
  '((t :inherit font-lock-builtin-face))
  "Face used for \\='buffer-name segment."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline)

(defface project-headerline-segment-separator
  '((t :inherit shadow :height 0.8))
  "Face used for separator between segments."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline)

(defface project-headerline-path-separator
  '((t :inherit shadow :height 0.8))
  "Face used for between path components inside `path-in-project' segment."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline)

(defface project-headerline-space
  '((t :height 0.5))
  "Face used for spaces around segment and path separators."
  :package-version '(project-headerline . "0.2")
  :group 'project-headerline)

(defcustom project-headerline-display-segments
  '(
    ;; list of pre-defined symbols, each symbol corresponds to a segment
    project-name
    path-in-project
    buffer-name
    ;;
    )
  "Which segments to show and in what order.

Must be a list of symbols, where each symbol represents a segment:

  - `project-name' - name of project where current file belongs
  - `path-in-project' - relative path from project root up to the current file
  - `buffer-name' - file name or buffer name

`path-in-project' segment is present only if buffer is file or directory.
`buffer-name' segment displays file or directory name if buffer is visiting one,
and uses function (buffer-name) otherwise."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type '(repeat
          (choice (const :tag "Project name." project-name)
                  (const :tag "Directories up to project." path-in-project)
                  (const :tag "Buffer or file name." buffer-name)))
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-segment-separator nil
  "String or icon to separate segments.

Icon is actually also a string, but with special properties.
For example, you can create one using `all-the-icons-material'.

When separator is nil, `project-headerline-icon-function' is used
to create it with default icon name."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type '(choice (const :tag "Default" nil)
                 string)
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-path-separator nil
  "String or icon to separate path components inside \\='path-in-project segment.

Icon is actually also a string, but with special properties.
For example, you can create one using `all-the-icons-material'.

When separator is nil, `project-headerline-icon-function' is used
to create it with default icon name."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type '(choice (const :tag "Default" nil)
                 string)
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-path-ellipsis "..."
  "String or icon used when \\='path-in-project' segment is truncated.

If the segment is too long, a few leading path components are
replaced with the value of this variable."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type 'string
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-detect-alist
  `(
    ;; detect using projectile, if installed
    (projectile :allow-remote nil
                :describe ,(lambda ()
                             (when (and (featurep 'projectile)
                                        (projectile-project-p))
                               (list :name (projectile-project-name)
                                     :path (projectile-project-root)))))
    ;; detect using builtin project.el package
    (project :allow-remote nil
             :describe ,(lambda ()
                          (when-let* ((project (project-current)))
                            (list :name (f-base (project-root project))
                                  :path (project-root project)))))
    ;; detect using magit, if installed
    (magit :allow-remote nil
           :describe ,(lambda ()
                        (when (featurep 'magit)
                          (when-let* ((magit-root (magit-toplevel)))
                            (list :name (f-filename magit-root)
                                  :path (f-full magit-root))))))
    ;; detect using builtin vc package
    (vc :allow-remote nil
        :describe ,(lambda ()
                     (when-let* ((vc-root (vc-root-dir)))
                       (list :name (f-filename vc-root)
                             :path (f-full vc-root)))))
    ;;
    )
  "Assoc list of project detection methods.

Assoc list key is a symbol of your choice.
Assoc list value is a plist with the following properties:
  - `:allow-remote' - whether to use this method on remote files
  - `:describe' - detection function

`:allow-remote' is by default disabled for all methods because it
may be very slow (depending on your connection).

Detection function should take no arguments and return a plist:
  - `:name' - project name
  - `:path' - project path (tramp paths are allowed)

Detection methods are tried one by one, until some of them
returns non-nil.

Used by default implementation of
`project-headerline-describe-project-function'."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type '(alist :key-type symbol
                :value-type (plist :options ((:allow-remote boolean)
                                             (:describe function))))
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-fallback-alist
  '(
    ;; pseudo-project "~" for all orphan files under $HOME
    ("~" . "~/")
    ;; pseudo-project "/" for all other orphan files
    ("/" . "/")
    ;;
    )
  "Assoc list of fallback projects when normal detection fails.

Assoc list key is project name.
Assoc list value is project path.

If no project was detected using `project-headerline-detect-alist',
then `project-headerline-fallback-alist' is scanned.  A fallback
project is selected if it's path is the parent of buffer's path.

You can use it both for real projects with hard-coded paths
\(e.g. if they're not identified by common methods), and for
fallbacks for buffers that don't really belong to a project.

By default, two `pseudo projects` are registered: `~' for any
file inside home directory, and `/' for any file elsewhere
on filesystem.  You can disable this by removing corresponding
elements from the assoc list."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type '(alist :key-type (string :tag "Project Name")
                :value-type (string :tag "Project Path"))
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-rename-alist
  '(
    ;; magit
    ("^\\(magit\\):.*" . "\\1")
    ("^\\(magit-[a-z]+\\):.*" . "\\1")
    ;; compilation
    ("^\\*compilation\\*<.*>" . "compilation")
    ("^\\*compilation<.*>\\*" . "compilation")
    ;;
    )
  "Assoc list of buffer rename rules.

Assoc list key is a regular expression.
Assoc list value is a replacement string that can use capture groups.

Keys and values are passed to `replace-regexp-in-string' and FROM and
TO arguments.  If any of the rule matches buffer, buffer name displayed
in headerline is changed according to the replacement."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type '(alist :key-type (string :tag "Buffer Name Regexp")
                :value-type (string :tag "Buffer Name Replacement"))
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-describe-project-function
  #'project-headerline-describe-project
  "Function that returns properties of current project.

Takes no arguments and returns plist:
  - `:name' - project name
  - `:path' - project directory path

Default implementation uses the following algorithm:
  - if `project-headerline-current-project' is set, uses it
  - tries rules from `project-headerline-detect-alist'
  - tries paths from `project-headerline-fallback-alist'"
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type 'function
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-describe-buffer-function
  #'project-headerline-describe-buffer
  "Function that returns properties of current buffer.

Takes no arguments and returns plist:
  - `:type' - kind of buffer, one of the symbols: `file', `dir', `other'
  - `:dir' - path to buffer's directory
  - `:name' - name of buffer

For `file' buffers, `:dir' is path to directory containing the file.
For `dir' buffers, `:dir' is path to directory itself.
For `other' buffers, `:dir' is path to a directory associated with
the buffer, typically `default-directory' inside that buffer.

Default implementation reports `dir' for Dired buffers, `file' for
buffers with non-empty variable `buffer-file-name', and `other' for
the rest.  It also applies buffer renaming rules according to variable
`project-headerline-rename-alist'."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type 'function
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-format-function
  #'project-headerline-format
  "Function to format headerline from project and buffer properties.

Takes two arguments:
  - `project' - plist from `project-headerline-describe-project-function'
  - `buffer' - plist from `project-headerline-describe-buffer-function'

Returns propertized string with headerline contents.

Default implementation formats headerline according to variables
`project-headerline-display-segments', `project-headerline-segment-separator',
`project-headerline-path-separator' (or `project-headerline-icon-function'),
and applies corresponding faces."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type 'function
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-icon-function
  #'project-headerline-icon
  "Function to create icon from name.

Takes two arguments:
  - `icon-name' - string name of the icon
  - `icon-face' - face to apply to the icon

Returns propertized string with the icon.
If icon is not available, returns nil.  In this case fallback
character will be used instead of the icon.

Default implementation uses `all-the-icons-material' when it's
available, or returns nil otherwise."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type 'function
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-width-function
  #'project-headerline-width
  "Function to return maximum headerline width.
Takes no arguments and returns number of characters."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type 'function
  :initialize 'custom-initialize-default
  :set 'project-headerline--set-variable)

(defcustom project-headerline-mode-list
  '(prog-mode
    conf-mode
    text-mode
    dired-mode)
  "Modes in which to enable `project-headerline-mode' automatically.

When `global-project-headerline-mode' is enabled, it enables headerline
in buffer if its major mode is derived from one of these modes.

Note that minibuffer and hidden buffers are always excluded."
  :package-version '(project-headerline . "0.1")
  :group 'project-headerline
  :type '(repeat symbol))

(defvar-local project-headerline-current-project nil
  "Overwrite current project path.

If this variable is set, it is used instead of `project-headerline-detect-alist'
and `project-headerline-fallback-alist' and defines project name and path.

It can be either a string or a list:

 - If it's a string, it should be a path to project directory.  Project name
   is set to the directory name.

 - If it's a list, it should be a plist with project properties, in the same
   format as returned by `project-headerline-describe-project-function'.

It's convenient to set this from local variables, e.g. in `.dir-locals.el'
in the project root.")

;; Forward-declate mode variable.
(defvar project-headerline-mode)

(defun project-headerline--set-variable (symbol value)
  "Setter for defcustom.
Assigns value to variable and invokes `project-headerline-reset'."
  (set-default-toplevel-value symbol value)
  (project-headerline-reset))

(defvar-local project-headerline--cache nil)

(defmacro project-headerline--cached (key form)
  "Cached evaluation of form.
If there is cached value for KEY, return it.
Otherwise, evaluate FORM, store in cache, and return it."
  `(let ((cache project-headerline--cache))
     (unless cache
       (setq cache (make-hash-table :test 'eq))
       (setq-local project-headerline--cache cache))
     (or (gethash ,key cache)
         (puthash ,key ,form cache))))

(defmacro project-headerline--call (func-or-cons &rest args)
  "Call user function.
On error, display warning and return nil."
  (let ((func (if (consp func-or-cons)
                  (car func-or-cons)
                func-or-cons))
        (name (if (consp func-or-cons)
                  (cdr func-or-cons)
                (symbol-name func-or-cons))))
    `(condition-case err
         (funcall ,func ,@args)
       (error
        (warn "Caught error from %s: %s" ,name
              (error-message-string err))
        nil))))

(defun project-headerline-describe-project ()
  "Get current project properties.
Default implementation of `project-headerline-describe-project-function',
see its docstring for details."
  (or (project-headerline--project-from-variable)
      (project-headerline--project-from-detect-alist)
      (project-headerline--project-from-fallback-alist)))

(defun project-headerline--project-from-variable ()
  "Get project from `project-headerline-current-project'."
  (when project-headerline-current-project
    (cond ((stringp project-headerline-current-project)
           (list :name (f-filename project-headerline-current-project)
                 :path (f-full project-headerline-current-project)))
          ((plistp project-headerline-current-project)
           project-headerline-current-project)
          (t
           (warn "Invalid project-headerline-current-project")
           nil))))

(defun project-headerline--project-from-detect-alist ()
  "Get project from `project-headerline-detect-alist'."
  (seq-some (lambda (method)
              (let ((allow-remote (plist-get (cdr method) :allow-remote))
                    (describe-fn (plist-get (cdr method) :describe)))
                (when (and (or allow-remote
                               (not (file-remote-p default-directory)))
                           describe-fn)
                  (project-headerline--call
                   (describe-fn . "project-headerline-detect-alist :describe")))))
            project-headerline-detect-alist))

(defun project-headerline--project-from-fallback-alist ()
  "Get project from `project-headerline-fallback-alist'."
  (let* ((directory (project-headerline--buffer-dir))
         (server (file-remote-p directory)))
    (when directory
      (seq-some (lambda (proj)
                  (let ((proj-name (car proj))
                        (proj-path (cdr proj)))
                    (if server
                        (when (s-prefix-p (expand-file-name (s-concat server proj-path))
                                          (expand-file-name directory))
                          (list :name (s-concat server proj-name)
                                :path (expand-file-name (s-concat server proj-path))))
                      (when (s-prefix-p (f-full proj-path)
                                        (f-full directory))
                        (list :name proj-name
                              :path (f-full proj-path))))))
                project-headerline-fallback-alist))))

(defun project-headerline-describe-buffer ()
  "Get current buffer properties.
Default implementation of `project-headerline-describe-buffer-function',
see its docstring for details."
  (let ((type (project-headerline--buffer-type))
        (dir (project-headerline--buffer-dir))
        (name (project-headerline--buffer-name)))
    (setq name
          (or (seq-some (lambda (rule)
                          (let ((from (car rule))
                                (to (cdr rule)))
                            (when (string-match from name)
                              (replace-regexp-in-string from to name))))
                        project-headerline-rename-alist)
              name))
    (list :type type
          :dir dir
          :name name)))

(defun project-headerline--buffer-type ()
  "Detect current buffer's type."
  (cond
   ;; dired
   ((derived-mode-p 'dired-mode)
    'dir)
   ;; special
   ((derived-mode-p 'special-mode)
    'other)
   ;; file
   (buffer-file-name
    'file)
   ;; very special
   (t
    'other)))

(defun project-headerline--buffer-dir ()
  "Detect current buffer's directory.
Returns path with trailing slash or nil."
  (cond
   ;; dired
   ((and (derived-mode-p 'dired-mode)
         (bound-and-true-p dired-subdir-alist))
    (f-full (dired-current-directory)))
   ;; file
   (buffer-file-name
    (f-slash (f-parent (f-full buffer-file-name))))
   ;; cwd
   (default-directory
    (f-full default-directory))))

(defun project-headerline--buffer-name ()
  "Detect current buffer's name.
For files and directories, returns base name.
Otherwise returns buffer name."
  (cond
   ;; dired
   ((and (derived-mode-p 'dired-mode)
         (bound-and-true-p dired-subdir-alist))
    (f-filename (dired-current-directory)))
   ;; file
   (buffer-file-name
    (f-filename buffer-file-name))
   ;; other
   (t
    (buffer-name))))

;; Forward-declare to ensure they are not byte-compiled as lexical.
(defvar all-the-icons-scale-factor)
(defvar all-the-icons-default-adjust)

(defun project-headerline-icon (icon-name icon-face)
  "Format propertized icon string from icon name and face.
Default implementation of `project-headerline-icon-function',
see its docstring for details."
  (when (functionp 'all-the-icons-material)
    (let ((all-the-icons-scale-factor 1.0)
          (all-the-icons-default-adjust -0.15))
      (when-let* ((icon (all-the-icons-material icon-name :face icon-face))
                  (space (propertize " " 'font-lock-face 'project-headerline-space)))
        (s-concat
         space icon space)))))

(defun project-headerline-width ()
  "Return maximum number of characters in headerline.
Default implementation of `project-headerline-width-function',
see its docstring for details."
  (window-width))

(defun project-headerline--separator (key default-icon default-char)
  "Make propertized icon string."
  (project-headerline--cached
   key
   (let ((var-name (intern (format "project-headerline-%s-separator" key)))
         (face-name (intern (format "project-headerline-%s-separator" key))))
     (or
      ;; user variable
      (symbol-value var-name)
      ;; default icon
      (project-headerline--call project-headerline-icon-function
                                default-icon face-name)
      ;; default char
      (let ((char (propertize default-char 'font-lock-face face-name))
            (space (propertize " " 'font-lock-face 'project-headerline-space)))
        (s-concat space char space))))))

(defun project-headerline--path-components (root-path path)
  "Split path from ROOT-PATH to CURR-PATH into components."
  (let (path-components)
    (while (and path
                (or (not root-path)
                    (not (f-same-p root-path path))))
      (push (f-filename path) path-components)
      (setq path (f-parent path)))
    path-components))

(defun project-headerline-format (project buffer)
  "Format headerline string for project and buffer.
Default implementation of `project-headerline-format-function',
see its docstring for details."
  (let* ((separator
          (project-headerline--separator 'segment "chevron_right" ">"))
         (margin
          (- (or (car (window-margins)) 0)))
         (max-width (project-headerline--call
                     project-headerline-width-function))
         (max-path (- max-width
                      (seq-reduce
                       '+ (seq-map (lambda (segment)
                                     (if (eq segment 'path-in-project)
                                         0
                                       (let ((str (project-headerline--format-segment
                                                   segment project buffer 0)))
                                         (unless (s-blank-p str)
                                           (+ (length separator)
                                              (length str))))))
                                   project-headerline-display-segments)
                       (length separator))))
         (segments (seq-map
                    (lambda (segment)
                      (project-headerline--format-segment
                       segment project buffer max-path))
                    project-headerline-display-segments))
         (headerline (s-join separator
                             (append '("")
                                     (seq-remove 's-blank-p
                                                 segments)))))
    (put-text-property 0 1 'display `(space :align-to ,margin)
                       headerline)
    headerline))

(defun project-headerline--format-segment (segment project buffer max-path)
  "Build segment with given name."
  (pcase segment
    (`project-name
     (project-headerline--format-project-name
      project buffer))
    (`path-in-project
     (project-headerline--format-path-in-project
      project buffer max-path))
    (`buffer-name
     (project-headerline--format-buffer-name
      project buffer))))

(defun project-headerline--format-project-name (project buffer)
  "Build \\='project segment."
  (ignore buffer)
  (let ((project-name (plist-get project :name)))
    (when (s-present-p project-name)
      (propertize project-name
                  'font-lock-face 'project-headerline-project-name))))

(defun project-headerline--format-path-in-project (project buffer max-path)
  "Build \\='path-in-project segment."
  (let* ((project-path (plist-get project :path))
         (buffer-type (plist-get buffer :type))
         (buffer-dir (plist-get buffer :dir))
         (path-in-project (cond
                           ;; directory
                           ((eq buffer-type 'dir)
                            (if (and (seq-contains-p project-headerline-display-segments
                                                     'buffer-name)
                                     (not (f-same-p project-path
                                                    buffer-dir)))
                                (f-parent buffer-dir)
                              buffer-dir))
                           ;; file or other
                           (t buffer-dir)))
         (components (project-headerline--path-components project-path
                                                          path-in-project))
         (separator
          (project-headerline--separator 'path "chevron_right" ">")))
    (when components
      (let ((max-components (length components))
            result)
        (while (or (not result)
                   (and (> (length result) max-path 2)
                        (> max-components 0)))
          (setq result
                (s-join separator
                        (seq-map (lambda (seg)
                                   (propertize
                                    seg 'font-lock-face 'project-headerline-path-in-project))
                                 (if (= max-components (length components))
                                     components
                                   (append (list project-headerline-path-ellipsis)
                                           (seq-drop components
                                                     (- (length components)
                                                        max-components)))))))
          (setq max-components (1- max-components)))
        result))))

(defun project-headerline--format-buffer-name (project buffer)
  "Build \\='buffer segment."
  (let* ((project-path (plist-get project :path))
         (buffer-type (plist-get buffer :type))
         (buffer-dir (plist-get buffer :dir))
         (buffer-name (plist-get buffer :name))
         (display-name (cond
                        ;; project root
                        ((and (eq buffer-type 'dir)
                              (f-same-p project-path buffer-dir))
                         ".")
                        ;; anything else
                        (t
                         buffer-name))))
    (when (s-present-p display-name)
      (propertize display-name
                  'font-lock-face 'project-headerline-buffer-name))))

(defun project-headerline--compose ()
  "Build propertized headerline string."
  (project-headerline--cached
   'headerline
   (or
    (when-let* ((project (project-headerline--call
                          project-headerline-describe-project-function))
                (buffer (project-headerline--call
                         project-headerline-describe-buffer-function)))
      (project-headerline--call
       project-headerline-format-function project buffer))
    "")))

(defun project-headerline--composer-match (elem func)
  "Match `header-line-format' element by composer function."
  (when-let* ((form (car-safe (cdr-safe elem))))
    (and (eq (car form) :eval)
         (eq (caadr form) func))))

(defun project-headerline--composer-append (func &rest args)
  "Add composer function to the head of `header-line-format'."
  (when (and header-line-format
             (not (listp header-line-format)))
    (setq header-line-format
          (list header-line-format)))
  (unless (seq-find (lambda (elem)
                      (project-headerline--composer-match elem func))
                    header-line-format)
    (setq header-line-format
          (append header-line-format
                  `((t (:eval (,func ,@args))))))))

(defun project-headerline--composer-prepend (func &rest args)
  "Add composer function to the tail of `header-line-format'."
  (when (and header-line-format
             (not (listp header-line-format)))
    (setq header-line-format
          (list header-line-format)))
  (unless (seq-find (lambda (elem)
                      (project-headerline--composer-match elem func))
                    header-line-format)
    (setq header-line-format
          (append `((t (:eval (,func ,@args))))
                  header-line-format))))

(defun project-headerline--composer-remove (func)
  "Remove composer function from `header-line-format'."
  (when (listp header-line-format)
    (setq header-line-format
          (seq-remove (lambda (elem)
                        (project-headerline--composer-match elem func))
                      header-line-format))))

(defun project-headerline--magit-compose (text)
  "Build magit headerline.
If `project-headerline-mode' is off, produces same result as original
`magit-set-header-line-format'.  Otherwise, produces right-aligned
headerline that can be use together with `project-headerline'."
  (project-headerline--cached
   'magit-headerline
   (s-concat
    (propertize " " 'display
                (if project-headerline-mode
                    (let* ((margin (or (cdr (window-margins)) 0))
                           (offset (- (length text)
                                      margin)))
                      `(space :align-to (- right-margin ,offset)))
                  '(space :align-to 0)))
    text)))

(defun project-headerline--magit-advice (orig-fn &rest args)
  "Wraps magit headrline builder to support `project-headerline' in magit buffers.
If you don't use project-headerline with magit, no visible changes are made."
  ;; safety check: don't follow advice if signature doesn't
  ;; match what it used to be
  (if (and (eq 1 (length args))
           (stringp (car args)))
      (project-headerline--composer-append 'project-headerline--magit-compose
                                           (car args))
    (apply orig-fn args)))

(defun project-headerline--rename-file-advice (orig-fn &rest args)
  "Wraps `rename-file' to update headerline on name change."
  (unwind-protect
      (apply orig-fn args)
    (let ((from (car args))
          (to (cadr args)))
      (project-headerline--reset-paths from to))))

(defun project-headerline--add-name-to-file-advice (orig-fn &rest args)
  "Wraps `add-name-to-file' to update headerline on name change."
  (unwind-protect
      (apply orig-fn args)
    (let ((from (car args))
          (to (cadr args)))
      (project-headerline--reset-paths from to))))

(defun project-headerline--rename-buffer-advice (orig-fn &rest args)
  "Wraps `rename-buffer' to update headerline on name change."
  (unwind-protect
      (apply orig-fn args)
    (project-headerline--reset-buffer)))

(defun project-headerline--enable-maybe ()
  "Enable `project-headerline-mode' in current buffer, if needed.
Headerline is enabled if buffer major mode is derived from one of the modes
in `project-headerline-mode-list'.
Never enables in minibuffer and hidden buffers."
  (when (and (not (minibufferp))
             (not (string-match "^ " (buffer-name)))
             (seq-some #'derived-mode-p project-headerline-mode-list)
             (not project-headerline-mode))
    (project-headerline-mode 1)))

(defun project-headerline--register-advices ()
  "Register all advices, if not registered yet."
  (when (featurep 'magit)
    (advice-add 'magit-set-header-line-format
                :around #'project-headerline--magit-advice))
  (advice-add 'rename-file
              :around #'project-headerline--rename-file-advice)
  (advice-add 'add-name-to-file
              :around #'project-headerline--add-name-to-file-advice)
  (advice-add 'rename-buffer
              :around #'project-headerline--rename-buffer-advice))

(defun project-headerline--register-hooks ()
  "Register all hooks."
  (add-hook 'window-configuration-change-hook
            #'project-headerline--reset-buffer nil :local)
  (add-hook 'after-revert-hook
            #'project-headerline--reset-buffer nil :local)
  (add-hook 'after-set-visited-file-name-hook
            #'project-headerline--reset-buffer nil :local))

(defun project-headerline--unregister-hooks ()
  "Unregister all hooks."
  (remove-hook 'window-configuration-change-hook
               #'project-headerline--reset-buffer :local)
  (remove-hook 'after-revert-hook
               #'project-headerline--reset-buffer :local)
  (remove-hook 'after-set-visited-file-name-hook
               #'project-headerline--reset-buffer :local))

(defun project-headerline--reset-buffer (&optional buffer)
  "Refresh headerline in given BUFFER (or current)."
  (with-current-buffer (or buffer (current-buffer))
    (when (bound-and-true-p project-headerline--cache)
      (setq-local project-headerline--cache nil))
    (when project-headerline-mode
      (force-mode-line-update))))

(defun project-headerline--reset-paths (&rest paths)
  "Refresh headerline in buffers visiting any of PATHS."
  (dolist (buffer (buffer-list))
    (when-let* ((buffer-path (buffer-file-name buffer)))
      (dolist (path paths)
        (when (and path (f-same-p buffer-path path))
          (project-headerline--reset-buffer buffer))))))

;;;###autoload
(defun project-headerline-reset (&optional buffer)
  "Forcibly refresh headerline in all buffers.
If BUFFER is given, refresh only that buffer."
  (interactive)
  (if buffer
      (project-headerline--reset-buffer buffer)
    (dolist (buffer (buffer-list))
      (project-headerline--reset-buffer buffer))))

;;;###autoload
(define-minor-mode project-headerline-mode
  "Customizable project headerline."
  :group 'project-headerline
  :init-value nil
  :lighter nil
  (if project-headerline-mode
      ;; enable mode
      (progn
        (project-headerline--composer-prepend 'project-headerline--compose)
        (project-headerline--register-advices)
        (project-headerline--register-hooks)
        (force-mode-line-update))
    ;; disable mode
    (project-headerline--unregister-hooks)
    (project-headerline--composer-remove 'project-headerline--compose)
    (project-headerline--reset-buffer)
    (force-mode-line-update)))

;;;###autoload
(define-globalized-minor-mode global-project-headerline-mode
  project-headerline-mode
  project-headerline--enable-maybe
  :group 'project-headerline)

(provide 'project-headerline)
;;; project-headerline.el ends here
