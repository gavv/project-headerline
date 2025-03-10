(package "project-headerline"
         "0.4"
         "Customizable project headerline")

(website-url "https://github.com/gavv/project-headerline")
(keywords "convenience")
(license "GPLv3")

(package-file "project-headerline.el")

(source "gnu")
(source "melpa")

(depends-on "emacs" "28.2")
(depends-on "f")
(depends-on "s")
(depends-on "all-the-icons")

;; These dependencies are optional and we don't list them in Package-Requires.
;; However, we want to enable them when byte-compiling on CI, so we use
;; "eask install-deps --dev" for that.
(development
 (depends-on "seq")
 (depends-on "magit")
 (depends-on "projectile"))

;; Allow setting checkdoc flags via local variables during eask invocation.
(put 'checkdoc--argument-missing-flag
     'safe-local-variable
     #'booleanp)
