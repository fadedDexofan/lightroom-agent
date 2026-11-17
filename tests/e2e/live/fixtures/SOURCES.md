# Bundled test photos

Two photos from the web for the checks no synthetic image can serve. Both are stored unchanged; `manifest.json` pins their SHA-256.

## portrait_cc0.jpg

- What: a black-and-white portrait of a bearded man with long hair, 4000x5000 JPEG. Used for People masks and for certification's Subject and combine steps.
- Source: https://commons.wikimedia.org/wiki/File:Bearded_man_with_long_hair-3052641.jpg, from Pixabay, by subhamshome28.
- Licence: CC0 1.0 (public domain dedication). No attribution is required; it is given anyway.
- SHA-256: `aa0467d2605c92d3ddc5eed890be3dab5cf3f9cda21d98182c9b918e1d873af7`

## iphone_portrait_photo.heic

- What: an iPhone Portrait-mode HEIC, 3024x4032, of a glass of tea on a table, carrying a depth map (auxiliary image `urn:mpeg:hevc:2015:auxid:2` with disparity metadata) and an HDR gain map. Used for the depth range mask.
- Source: https://github.com/openize-com/openize-heic-net, file `Openize.Heic.Tests/TestsData/samples/iphone_portrait_photo.heic`.
- Licence: the Openize License, derived from the BSD 2-Clause License. Its notice, reproduced as its second condition requires:

```text
Openize.HEIC is available under Openize License.

This license is derived from BSD 2 Clause License and Third-party patents clause.

Copyright (c) 2024-2026 Openize Pty Ltd.

Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the following conditions are met:
1. Redistributions of source code must retain the above copyright notice, this list of conditions
and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of
conditions and the following disclaimer in the documentation and/or other materials provided with
the distribution.

THIRD-PARTY PATENTS.
Openize.HEIC contains HEVC/H.265 image compression/decompression technologies that are covered by
third party patents. Openize does not and cannot grant You a patent license for the utilization
of HEVC/H.265 image compression/decompression technologies. If You create End User Software that
utilizes the HEVC/H.265 image compression/decompression technologies included in Openize.HEIC then 
You are responsible for obtaining any required third-party patent licenses for the deployment and
distribution of Your End User Software. You agree to indemnify and hold Openize harmless from any 
and all patent claims that arise from the deployment and distribution of Your End User Software 
that utilizes the HEVC/H.265 image compression/decompression technologies included in Openize.HEIC.
If You plan on using the HEVC/H.265 image compression/decompression technologies included in 
Openize.HEIC in Your End User Software and You would like contact details for the patent holders,
then please consider https://en.wikipedia.org/wiki/High_Efficiency_Video_Coding.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS “AS IS” AND ANY EXPRESS OR 
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND 
FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR 
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL 
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, 
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT 
OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

- SHA-256: `c782e03d1ef2a709f6a84ff1b1612ef2dfa909e4872958d3975e15c79ab523c3`
