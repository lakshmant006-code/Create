# Petal Physics — interactive particle garden

Open `index.html` in a modern browser (no installation or dependencies). Drag over foliage, tap to disturb it, change wind / gravity / release, press Gust, and switch to dark mode.

## Physics model

Each attached leaf is static until release. Released leaves are independent particles integrated using fixed-ish substeps (`dt <= 0.012 s`). Forces include gravity, a spatially and temporally varying horizontal wind field, linear horizontal drag, quadratic vertical air resistance, and oscillatory flutter/lift. The resulting equations approximate `a_x = F_wind/m + F_flutter/m - c_x v_x` and `a_y = g + F_lift/m - c_y v_y |v_y|`. Leaves also have independently oscillating angular velocities and collision response against the ground. A spatial falloff kernel applies pointer-driven gust forces and triggers localized leaf release.

## Assets

`assets/cherry-petal.svg`, `assets/maple-leaf.svg`, `assets/green-leaf.svg` are editable standalone shapes. Tree trunks, branch geometry, and canopies are generated procedurally on HTML Canvas, so there are no giant flattened sprite sheets. To replace with bespoke artwork, swap the canvas `leafShape()` renderer with sprite rendering or use the SVG elements as source templates.

## Iteration 2: elastic branches and leaf tumbling

- **Elastic branches.** Every branch is a damped torsional spring hanging off its parent. Wind (and the pointer) applies torque `-w·sin(angle)`, so the trunk barely leans while twigs whip, and angles accumulate down the tree. Foliage is bound to its nearest twig tip and rides it, so canopies move as coherent clumps. A leaf that detaches inherits its twig's velocity.
- **Tumbling.** Released leaves use a flat-plate model: drag acts on the velocity component normal to the leaf, so a tilted leaf glides sideways. A restoring torque swings it broadside to the relative airflow. A Van der Pol term pumps energy in until the swing reaches a per-species amplitude: small for boxwood and maple (flutter), large for petals (overshoot and full tumbles). A separate `roll` angle drives the face-on / edge-on foreshortening.

## Production upgrades

- Add spatial noise for coherent gusts, rather than the present low-frequency sinusoidal field.
- Add broadphase spatial hashing if scaling past ~5,000 flying leaves.
- Add sprite atlas, GPU instancing, and alpha blending for dense scenes.
- Optional controls: wind direction, turbulence, seasonal release, branch elasticity, and pointer brush radius.
