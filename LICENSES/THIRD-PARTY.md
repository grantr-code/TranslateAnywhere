# Third-Party Licenses

TranslateAnywhere uses the following third-party libraries and models. We gratefully acknowledge the work of their respective authors and communities.

---

## CTranslate2

- **Project:** [OpenNMT/CTranslate2](https://github.com/OpenNMT/CTranslate2)
- **License:** MIT License
- **Copyright:** Copyright (c) 2018 OpenNMT
- **Usage:** CTranslate2 is the inference engine used to run OPUS-MT translation models efficiently on CPU. It is compiled from source and linked as a static library.
- **License file:** [MIT.txt](MIT.txt)

The full MIT License text applies as reproduced in `LICENSES/MIT.txt`.

---

## SentencePiece

- **Project:** [google/sentencepiece](https://github.com/google/sentencepiece)
- **License:** Apache License, Version 2.0
- **Copyright:** Copyright 2016 Google Inc.
- **Usage:** SentencePiece provides subword tokenization and detokenization for the OPUS-MT models. It is compiled from source and linked as a static library.
- **License file:** [APACHE-2.0.txt](APACHE-2.0.txt)

Licensed under the Apache License, Version 2.0. You may obtain a copy of the License at:
http://www.apache.org/licenses/LICENSE-2.0

---

## OPUS-MT Models (Runtime Download)

- **Project:** [Helsinki-NLP/OPUS-MT](https://github.com/Helsinki-NLP/OPUS-MT)
- **License:** Creative Commons Attribution 4.0 International (CC-BY-4.0)
- **Copyright:** Copyright Helsinki-NLP / University of Helsinki
- **Usage:** The pre-trained OPUS-MT English/Russian pairs are downloaded on demand from a model artifact repository and loaded at runtime via CTranslate2. The app supports both:
  - `opus-mt-en-ru` + `opus-mt-ru-en` (OPUS Base)
  - `opus-mt-en-zle` + `opus-mt-zle-en` (OPUS Big)
- **License file:** [CC-BY-4.0.txt](CC-BY-4.0.txt)
- **Attribution:** Jorg Tiedemann and Santhosh Thottingal, "OPUS-MT -- Building open translation services for the World," Proceedings of the 22nd Annual Conference of the European Association for Machine Translation, 2020.

---

## NLLB Models (Runtime Download)

- **Project:** [Meta AI NLLB](https://github.com/facebookresearch/fairseq/tree/main/examples/nllb)
- **Artifacts used:** `OpenNMT/nllb-200-distilled-1.3B-ct2-int8`, `OpenNMT/nllb-200-3.3B-ct2-int8`
- **License:** Creative Commons Attribution-NonCommercial 4.0 International (CC-BY-NC-4.0)
- **Usage:** Optional, heavier multilingual EN<->RU translation models downloaded on demand and run locally via CTranslate2.
- **License file:** [CC-BY-NC-4.0.txt](CC-BY-NC-4.0.txt)

---

## Rust Crates

### libc

- **Project:** [rust-lang/libc](https://github.com/rust-lang/libc)
- **License:** MIT License OR Apache License, Version 2.0 (dual-licensed)
- **Copyright:** Copyright (c) The Rust Project Developers
- **Usage:** Provides FFI type definitions and bindings to platform-specific C library APIs.

### once_cell

- **Project:** [matklad/once_cell](https://github.com/matklad/once_cell)
- **License:** MIT License OR Apache License, Version 2.0 (dual-licensed)
- **Copyright:** Copyright (c) Aleksey Kladov
- **Usage:** Provides lazy static initialization primitives used for the global translator instance.

### cc (build dependency)

- **Project:** [rust-lang/cc-rs](https://github.com/rust-lang/cc-rs)
- **License:** MIT License OR Apache License, Version 2.0 (dual-licensed)
- **Copyright:** Copyright (c) Alex Crichton
- **Usage:** Build-time tool for compiling C/C++ code as part of the Rust build process.

### pkg-config (build dependency)

- **Project:** [rust-lang/pkg-config-rs](https://github.com/rust-lang/pkg-config-rs)
- **License:** MIT License OR Apache License, Version 2.0 (dual-licensed)
- **Copyright:** Copyright (c) Alex Crichton
- **Usage:** Build-time tool for discovering system library paths and compiler flags via the pkg-config protocol.

---

## License Texts

The complete license texts referenced above are included in this directory:

- `MIT.txt` -- MIT License (CTranslate2, TranslateAnywhere, Rust crates)
- `APACHE-2.0.txt` -- Apache License, Version 2.0 (SentencePiece, Rust crates)
- `CC-BY-4.0.txt` -- Creative Commons Attribution 4.0 International (OPUS-MT models)
- `CC-BY-NC-4.0.txt` -- Creative Commons Attribution-NonCommercial 4.0 International (NLLB models)
