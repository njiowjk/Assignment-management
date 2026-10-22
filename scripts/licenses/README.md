# Supplemental upstream notices

`boolbase@1.0.0` declares ISC in its npm `package.json` but its published tarball
does not contain the license text. `boolbase-1.0.0-LICENSE.txt` preserves the
upstream [boolbase ISC license](https://github.com/fb55/boolbase/blob/master/LICENSE),
including the original copyright notice. This is a distribution notice, not an
application credential or a replacement for the upstream package.

All other bundled packages are discovered from esbuild's actual input files;
their LICENSE/COPYING/NOTICE files are copied from the installed, lockfile-pinned
package. Node.js's full license (including its third-party notices) is copied
from the SHA-256-verified official runtime archive.
