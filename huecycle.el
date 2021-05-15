;;; huecycle --- (TODO summary)                 -*- lexical-binding: t; -*-

;;; Commentary:

;;; TODO write me

;;; Code:

;; TODO document all functions
;; TODO checkdoc this file
;; TODO readme
;; TODO add config to not revert colors when moviing
;; - and should start lerping from where it left off
;; - stoer this as "local" lerping state
;; TODO link some face color transitions together
;; - common hashing?
;; - return to multiple faces in one config and rework starting color
;; TODO defcustom
;; clean up codes

(eval-when-compile (require 'cl-lib))

(defvar huecycle-step-size 0.01
  "Interval of time between color updates.")

(defvar huecycle--interpolate-data '()
  "List of `huecycle-interpolate-datum'.")

(defvar huecycle--idle-timer nil
  "Idle timer used to start huecycle.")

(defvar huecycle--default-start-color "#888888"
  "Start color to use if a face has none, and no color is specified.")

(cl-defstruct (huecycle--color (:constructor huecycle--color-create)
                               (:copier nil))
  "Color struct with named slots for hue, saturation, and luminance."
  hue saturation luminance)

(cl-defstruct (huecycle--interp-datum (:constructor huecycle--interp-datum-create)
                                 (:copier nil))
  "Struct holds all data and state for one color-interpolating face."
  (faces nil :documentation "Affected faces")
  (spec nil :documentation "Spec of face that is affected (should be `foreground', `background',
                                 `distant-foreground', or `distant-background')")
  (default-start-color nil :documentation "Start color to use over the faces spec")
  (start-colors '() :documentation "Start colors interpolated")
  (end-colors '() :documentation "End colors interpolated")
  (progress 0.0 :documentation "Current interpolation progress")
  (interp-func #'huecycle-interpolate-linear :documentation "Function used to interpolate values")
  (next-color-func #'huecycle-get-random-hsl-color :documentation "Function used to determine next color")
  (color-list '() :documentation "List of `huecycle--color' used by next-color-func")
  (random-color-hue-range '(0.0 1.0) :documentation "Range of hues that are randomly sampled in `huecycle-get-random-hsl-color'")
  (random-color-saturation-range '(0.5 1.0) :documentation "Range of saturation that are randomly sampled in `huecycle-get-random-hsl-color'")
  (random-color-luminance-range '(0.2 0.3) :documentation "Range of luminance that are randomly sampled in `huecycle-get-random-hsl-color'")
  (color-list-index 0 :documentation "Index used in next-color-func")
  (cookies nil :documentation "Cookies generated by `face-remap-add-relative'")
  (step-multiple 1.0 :documentation "Multiplier on how much to modify speed of interpolation"))

(defun huecycle--init-interp-datum (faces spec &rest rest)
  "Helper function to create an `huecycle--interp-datum'.
Create an `huecycle--interp-datum' the group specified by FACES that affects SPEC. FACES can be a single face, or
list of faces, and the spec is a symbol that is either `foreground', `background', `distant-foreground', or
`distant-background'.

REST are (KEYWORD VALUE) where KEYWORDs include:
- `:interp-func': Interpolation function (default: `huecycle-interpolate-linear').
- `:next-color-func': Function used to determine the next color to interpolate towards (default:
`huecycle-get-random-hsk-color').
- `:start-color': Color all faces will start with (overrides current spec color) (default: nil).
- `:color-list': List of `huecycle--color', used by `:next-color-func' (default: Empty list).
- `:speed': Speed of interpolation (default: 1.0).
- `:random-color-hue-range': range hue values are randomly chosen from (by `next-color-func'). Is a list of 2
  elements where first <= second (default: (0.0 1.0)).
- `:random-color-saturation-range': range saturation values are randomly chosen from (by `next-color-func'). Is a
  list of 2 elements where first <= second (default: (0.5 1.0)).
- `:random-color-luminance-range': range luminance values are randomly chosen from (by `next-color-func'). Is a list
- of 2 elements where first <= second (default: (0.2 0.3))."
  (huecycle--init-interp-datum-verify-args faces spec)
  (let (
        (interp-func (plist-get rest :interp-func))
        (next-color-func (plist-get rest :next-color-func))
        (start-color (plist-get rest :start-color))
        (color-list (plist-get rest :color-list))
        (step-multiple (plist-get rest :speed))
        (random-color-hue-range (plist-get rest :random-color-hue-range))
        (random-color-saturation-range (plist-get rest :random-color-saturation-range))
        (random-color-luminance-range (plist-get rest :random-color-luminance-range)))
  (huecycle--interp-datum-create
   :faces (if (listp faces) faces (list faces))
   :spec spec
   :interp-func (if interp-func interp-func #'huecycle-interpolate-linear)
   :default-start-color start-color
   :next-color-func (if next-color-func next-color-func #'huecycle-get-random-hsl-color)
   :color-list (if color-list (mapcar #'huecycle--hex-to-hsl-color color-list) '())
   :step-multiple (if step-multiple step-multiple 1.0)
   :random-color-hue-range (if random-color-hue-range random-color-hue-range '(0.0 1.0))
   :random-color-saturation-range (if random-color-saturation-range random-color-saturation-range '(0.5 1.0))
   :random-color-luminance-range (if random-color-luminance-range random-color-luminance-range '(0.2 0.3)))))

(defun huecycle--init-interp-datum-verify-args (faces spec)
  "Asserts input, FACES and SPEC, of `huecycle--init-interp-datum' is valid."
  (cond
   ((listp faces) (dolist (face faces) (cl-assert (facep face) "FACE in faces isn't a valid face")))
   (t (cl-assert (facep faces) "FACES isn't valid face")))
  (cl-assert (or (eq spec 'foreground) (eq spec 'background) (eq spec 'distant-foreground) (eq spec 'distant-background))
             "spec needs to refer to a color"))

(defun huecycle--hex-to-rgb (hex)
  "Convert HEX, a hex string with 2 digits per component, to rgb tuple."
  (cl-assert (length= hex 7) "hex string should have 2 digits per component")
  (let (
        (red
         (/ (string-to-number (substring hex 1 3) 16) 255.0))
        (green
         (/ (string-to-number (substring hex 3 5) 16) 255.0))
        (blue
         (/ (string-to-number (substring hex 5 7) 16) 255.0)))
    (list red green blue)))

(defun huecycle--hex-to-hsl-color (color)
  "Convert COLOR, a hex string color with 2 digits per component, to a `huecycle--color'."
  (pcase (apply 'color-rgb-to-hsl (huecycle--hex-to-rgb color))
    (`(,hue ,sat ,lum) (huecycle--color-create :hue hue :saturation sat :luminance lum))
    (`(,_) error "Could not parse hl-line")))

(defun huecycle--get-start-color (face spec)
  "Return current color of FACE based on SPEC."
  (let* ((attribute
          (cond
           ((eq spec 'foreground) (face-attribute face :foreground))
           ((eq spec 'background) (face-attribute face :background))
           ((eq spec 'distant-foreground) (face-attribute face :distant-foreground))
           ((eq spec 'distant-background) (face-attribute face :distant-background))
           (t 'unspecified)))
         (attribute-color (if (eq attribute 'unspecified) huecycle--default-start-color attribute))
         (hsl (apply #'color-rgb-to-hsl (huecycle--hex-to-rgb attribute-color))))
    (pcase hsl
      (`(,hue ,sat ,lum) (huecycle--color-create :hue hue :saturation sat :luminance lum))
      (`(,_) error "Could not parse color"))))

;; (defun huecycle--get-start-color (interp-datum)
;;   "Return the current background color of the hl-line as `huecycle--color'"
;;   (let* (
;;          (face (huecycle--interp-datum-face interp-datum))
;;          (spec (huecycle--interp-datum-spec interp-datum))
;;          (start-color (huecycle--interp-datum-default-start-color interp-datum))
;;          (attribute
;;           (cond
;;            (start-color start-color)
;;            ((eq spec 'foreground) (face-attribute face :foreground))
;;            ((eq spec 'background) (face-attribute face :background))
;;            ((eq spec 'distant-foreground) (face-attribute face :distant-foreground))
;;            ((eq spec 'distant-background) (face-attribute face :distant-background))
;;            (t 'unspecified)))
;;          (attribute-color (if (eq attribute 'unspecified) huecycle--default-start-color attribute))
;;          (hsl (apply #'color-rgb-to-hsl (huecycle--hex-to-rgb attribute-color))))
;;     (pcase hsl
;;       (`(,hue ,sat ,lum) (huecycle--color-create :hue hue :saturation sat :luminance lum))
;;       (`(,_) error "Could not parse color"))))


(defun huecycle-get-random-hsl-color (interp-datum)
  "Return random `huecycle--color' using ranges from INTERP-DATUM."
  (let (
        (hue-range (huecycle--interp-datum-random-color-hue-range interp-datum))
        (sat-range (huecycle--interp-datum-random-color-saturation-range interp-datum))
        (lum-range (huecycle--interp-datum-random-color-luminance-range interp-datum)))
  (huecycle--color-create
   :hue (huecycle--get-random-float-from (nth 0 hue-range) (nth 1 hue-range))
   :saturation (huecycle--get-random-float-from (nth 0 sat-range) (nth 1 sat-range))
   :luminance (huecycle--get-random-float-from (nth 0 lum-range) (nth 1 lum-range)))))

(defun huecycle--get-random-float-from (lower upper)
  "Gets random float from in range [lower, upper].
LOWER and UPPER should be in range [0.0, 1.0]"
  (cl-assert (and (>= lower 0.0) (<= lower 1.0)) "lower is not in range [0, 1]")
  (cl-assert (and (>= upper 0.0) (<= upper 1.0)) "upper is not in range [0, 1]")
  (cl-assert (<= lower upper) "lower should be <= upper")
  (if (= lower upper)
      (lower)
    (let* ((high-number 10000000000)
           (lower-int (truncate (* lower high-number)))
           (upper-int (truncate (* upper high-number))))
      (/ (* 1.0 (+ lower-int (random (- upper-int lower-int)))) high-number))))

(defun huecycle-get-next-hsl-color (interp-datum)
  "Get the next `hsl--color' from INTERP-DATUM's color list."
  (let ((color-list (huecycle--interp-datum-color-list interp-datum))
        (color-list-index (huecycle--interp-datum-color-list-index interp-datum)))
    (if (= (length color-list) 0)
       nil
      (setf (huecycle--interp-datum-color-list-index interp-datum)
            (mod (1+ color-list-index) (length color-list)))
      (nth (huecycle--interp-datum-color-list-index interp-datum) color-list))))

(defun huecycle-get-random-hsl-color-from-list (interp-datum)
  "Get random `hsl--color' from INTERP-DATUM's color list."
  (let ((color-list (huecycle--interp-datum-color-list interp-datum)))
    (if (length= (huecycle--interp-datum-color-list interp-datum) 0)
       nil
      (setf (huecycle--interp-datum-color-list-index interp-datum)
            (random (length color-list)))
      (nth color-list (huecycle--interp-datum-color-list-index interp-datum)))))

(defun huecycle--clamp (value low high)
  "Clamps VALUE between LOW and HIGH."
  (max (min value high) low))

(defun huecycle-interpolate-linear (progress start end)
  "Return new color that is the result of interplating the colors of START and END linearly.
PROFRESS is a float in the range [0, 1], but providing a value outside of that will extrapolate new values.
START and END are `huecycle--color'."
  (let ((new-hue
         (huecycle--clamp
          (+ (* (- 1 progress) (huecycle--color-hue start)) (* progress (huecycle--color-hue end))) 0 1))
        (new-sat
         (huecycle--clamp
          (+ (* (- 1 progress) (huecycle--color-saturation start)) (* progress (huecycle--color-saturation end))) 0 1))
        (new-lum
         (huecycle--clamp
          (+ (* (- 1 progress) (huecycle--color-luminance start)) (* progress (huecycle--color-luminance end))) 0 1)))
    (huecycle--color-create :hue new-hue :saturation new-sat :luminance new-lum)))

(defun huecycle--hsl-color-to-hex (hsl-color)
  "Convert HSL-COLOR, a `huecycle--color', to hex string with 2 digits for each component."
  (let ((rgb (color-hsl-to-rgb
              (huecycle--color-hue hsl-color)
              (huecycle--color-saturation hsl-color)
              (huecycle--color-luminance hsl-color))))
    (color-rgb-to-hex (nth 0 rgb) (nth 1 rgb) (nth 2 rgb) 2)))

(defun huecycle--update-progress (new-progress interp-datum)
  "Update INTERP-DATUM's progress by adding NEW-PROGRESS by INTERP-DATUM's multiple value."
  (let ((progress (huecycle--interp-datum-progress interp-datum))
        (multiple (huecycle--interp-datum-step-multiple interp-datum)))
    (setq progress (+ progress (* new-progress multiple)))
    (if (>= progress 1.0)
        (progn
          (setq progress 0.0)
          (huecycle--change-next-colors interp-datum)))
    (setf (huecycle--interp-datum-progress interp-datum) progress)))


(defun huecycle--reset-faces (interp-datum)
  "Remove all face modification for all faces in INTERP-DATUM."
  (let ((cookies (huecycle--interp-datum-cookies interp-datum)))
    (dolist (cookie cookies) (face-remap-remove-relative cookie))
    (setf (huecycle--interp-datum-cookies interp-datum) '())))

(defun huecycle--set-all-faces (interp-datum)
  "Apply all face-remaps for all faces in INTERP-DATUM."
  (let* ((faces (huecycle--interp-datum-faces interp-datum))
         (spec (huecycle--interp-datum-spec interp-datum))
         (interp-func (huecycle--interp-datum-interp-func interp-datum))
         (start-colors (huecycle--interp-datum-start-colors interp-datum))
         (end-colors (huecycle--interp-datum-end-colors interp-datum))
         (progress (huecycle--interp-datum-progress interp-datum))
         (args-length (min (length faces) (length start-colors) (length end-colors)))
         (args-list '()))
    ;; Build up args-list
    (dotimes (i args-length)
      (push (list (nth i faces) spec interp-func (nth i start-colors) (nth i end-colors) progress) args-list))
    ;; Create cookies from face-remaps and store them
    (let ((cookies (mapcar (lambda (list) (apply #'huecycle--set-face list)) args-list)))
      (setf (huecycle--interp-datum-cookies interp-datum) cookies))
    (dolist (face faces)
      (face-spec-recalc face (selected-frame)))))

(defun huecycle--set-face (face spec interp-func start-color end-color progress)
  "Apply face-remap for FACE's SPEC using INTERP-FUNC to interpolate START-COLOR and END-COLOR."
  (let ((new-color (huecycle--hsl-color-to-hex (funcall interp-func progress start-color end-color))))
    (cond ((eq 'background spec) (face-remap-add-relative face :background new-color))
          ((eq 'foreground spec) (face-remap-add-relative face :foreground new-color))
          ((eq 'distant-background spec) (face-remap-add-relative face :distant-background new-color))
          ((eq 'distant-foreground spec) (face-remap-add-relative face :distant-foreground new-color)))))

(defun huecycle--init-colors (interp-datum)
  "Initialize/Reset INTERP-DATUM by setting start and end colors.
Must be called before anhy other operations on the INTERP-DATUM."
  (let* ((next-color-func (huecycle--interp-datum-next-color-func interp-datum))
        (faces (huecycle--interp-datum-faces interp-datum))
        (spec (huecycle--interp-datum-spec interp-datum))
        (default-start-color (huecycle--interp-datum-default-start-color interp-datum))
        (faces-spec-list (mapcar (lambda (face) (list face spec)) faces))
        (start-colors-list
         (if default-start-color
             (make-list (length faces) default-start-color)
             (mapcar (lambda (face-spec) (apply #'huecycle--get-start-color face-spec)) faces-spec-list)))
        (next-colors-list (mapcar next-color-func (make-list (length faces) interp-datum))))
    (setf (huecycle--interp-datum-start-colors interp-datum) start-colors-list)
    (setf (huecycle--interp-datum-end-colors interp-datum) next-colors-list)
    (setf (huecycle--interp-datum-progress interp-datum) 0.0)))

(defun huecycle--change-next-colors (interp-datum)
  "Cycle INTERP-DATUM's start and end colors.
End colors become start colors, and the new end colors are determined by `huecycle--interp-datum-next-color-func'."
  (let* ((end-colors (huecycle--interp-datum-end-colors interp-datum))
         (faces (huecycle--interp-datum-faces interp-datum))
         (next-color-func (huecycle--interp-datum-next-color-func interp-datum))
         (next-colors-list (mapcar next-color-func (make-list (length faces) interp-datum))))
    (setf (huecycle--interp-datum-start-colors interp-datum) end-colors)
    (setf (huecycle--interp-datum-end-colors interp-datum) next-colors-list)))

;;;###autoload
(defun huecycle ()
  "Begin changing colors of faces specified by `huecycle--interpolate-data'."
  (interactive)
  (when huecycle--interpolate-data
    (mapc #'huecycle--init-colors huecycle--interpolate-data)
    (while (not (input-pending-p))
      (sit-for huecycle-step-size)
      (dolist (datum huecycle--interpolate-data)
        (huecycle--update-progress huecycle-step-size datum)
        (huecycle--reset-faces datum)
        (huecycle--set-all-faces datum)))
    (mapc #'huecycle--reset-faces huecycle--interpolate-data)))

;;;###autoload
(defun huecycle-stop-idle ()
  "Stop the colorization effect when idle."
  (interactive)
  (if huecycle--idle-timer
      (cancel-timer huecycle--idle-timer))
  (setq huecycle--idle-timer nil))

;;;###autoload
(defun huecycle-when-idle (secs)
  "Start huecycle affect aftre SECS seconds."
  (interactive "nHow long before huecycle-ing (seconds): ")
  "Starts the colorization effect. when idle for `secs' seconds"
  (huecycle-stop-idle)
  (if (>= secs 0)
      (setq huecycle--idle-timer (run-with-idle-timer secs t 'huecycle))))

(defmacro huecycle-set-faces (&rest faces)
  "Helper function to specify which FACES should huecycle."
  `(setq huecycle--interpolate-data (mapcar (apply-partially #'apply #'huecycle--init-interp-datum) ',faces)))

(provide 'huecycle)

;;; huecycle.el ends here
