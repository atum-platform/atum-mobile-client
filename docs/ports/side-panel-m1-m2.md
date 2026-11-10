# Phone side panel M1 + M2

Owner request (2026-11-10): port the in-flight phone panel container and
person/group info onto current public main; local commits only.
State: design dependency imported; scoped client port follows. Not live.

The existing design importer pins the public desktop producer at
`63e122d3a22fc6fdef252cf90e5a4a2e201b1e65`. Its manifest and all five
locales supply the person-info and block/unblock copy needed by this slice.
No vendored resources were edited manually. Verification: immutable import,
8 importer tests, push fixture check and 2 push projection tests passed.
