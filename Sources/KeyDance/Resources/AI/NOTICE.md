KeyWoo's optional local music experiment uses Magenta RealTime 2 small by the
Google / Magenta team. Model weights are downloaded separately and are not
included in this app bundle.

Model license: Creative Commons Attribution 4.0 International (CC BY 4.0).
Project/library license: Apache 2.0.

https://magenta.tensorflow.org/magenta-realtime-2
https://huggingface.co/google/magenta-realtime-2
https://github.com/magenta/magenta-realtime
https://creativecommons.org/licenses/by/4.0/

style-tokens.json contains precomputed model conditioning for two fixed generic
instrumental descriptions. Typed text is never used as a music prompt.

Music/keywoo-ai-seed.wav comes from the eight-second local baseline output,
with 50ms of leading silence removed. Music/keywoo-ai-variation.wav is seconds
4 through 8 of the paired style-change output from the same experiment. Neither
contains user typing or an imported song. Prepared loops allow music and an
initial variation to begin without waiting for a new model phrase. Subsequent
complete phrases are composed locally in the background; the model remains
outside this bundle.
