# Reference Implementations

Quick URL map so the skill can fetch the right source without guessing. All three projects are open-source and cover overlapping regions — cross-reference when one looks wrong.

## hyundai_kia_connect_api (Python)

- Repo root: https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api
- Region clients live under `hyundai_kia_connect_api/`:
  - `ApiImplType1.py` — shared base for newer clients (EU, AU, CA in some branches)
  - `ApiImplType2.py` — older USA clients
  - `HyundaiBlueLinkAPIUSA.py` — Hyundai USA
  - `KiaUvoAPIUSA.py` — Kia USA
  - `HyundaiBlueLinkACanada.py` — Hyundai Canada
  - `KiaUvoAPIEU.py`, `HyundaiBlueLinkAPIEU.py` — European
  - `KiaUvoAPIAU.py`, `HyundaiBlueLinkAPIAU.py` — Australia

Fetch raw files with `WebFetch`:
```
https://raw.githubusercontent.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/master/hyundai_kia_connect_api/<Filename>.py
```

## bluelinky (TypeScript)

- Repo root: https://github.com/Hacksore/bluelinky
- Region controllers: `src/controllers/<region>.controller.ts`
- Shared types: `src/interfaces/` and `src/vehicles/`
- Endpoint constants in each controller's top-of-file `CLIENT_ID` / base-URL block.

Fetch raw files with:
```
https://raw.githubusercontent.com/Hacksore/bluelinky/master/src/controllers/<region>.controller.ts
```

## egmp-bluelink-scriptable (TypeScript / Scriptable)

- Repo root: https://github.com/andyfase/egmp-bluelink-scriptable
- iOS-only Scriptable app targeting Hyundai/Kia E-GMP vehicles across US/CA/EU.
- Region clients live under `src/lib/bluelink-regions/` — each region is one self-contained file because Scriptable has no module system, so every endpoint and header the region uses is visible in a single scroll.
- Good second opinion when bluelinky and hyundai_kia_connect_api disagree.

Fetch raw files with `WebFetch`:
```
https://raw.githubusercontent.com/andyfase/egmp-bluelink-scriptable/main/src/lib/bluelink-regions/<region>.ts
```

## Cross-referencing tips

- **Endpoint paths** rarely change across clients because they're server-defined. If bluelinky and hyundai_kia_connect_api both point at `/api/v1/spa/vehicles`, trust it.
- **Header names** sometimes get wrapper-layer renaming — check which header the actual HTTP request sends, not the internal variable name.
- **Auth flows** differ most between implementations. Copy the one closest to the app version the user captured from, if possible.
- **Region-specific temperature encoding** often lives in a `_get_temperature_from_value()` helper or similar. Grep the reference for `temperature` and `airTemp`.
