# Cloud-only phone: no Mac homes, one model choice

Assistants live in the cloud. Macs are devices they can reach. The phone
follows the desktop's cloud-only change (`docs/ports/cloud-only-legacy-ui.md`
in atum-desktop): it never offers a Mac as a home, and the assistant card
edits the model of the place that answers now. Mac devices, sources and
permissions are unchanged, because assistants can still use Macs.

## What changes

- **Move sheet.** Its destinations list offers only the cloud
  (`AgentHomeSnapshot.offeredHomeDestinations`, from the earlier cloud-home
  port). A cloud assistant has nowhere else to move. An assistant that still
  lives on a Mac shows that Mac as its current place and can leave for the
  cloud.
- **Card Model page.** When only the 1.3/1.4 destination read is available,
  the card's Model row used to open a list with one row per destination: the
  cloud, then "Mac 1", "Mac 2" and so on. It now opens the cloud's picker
  directly (`ManagedModelDestinationSnapshot.cardDestination`). The snapshot
  keeps its Mac entries for older desktops; the phone no longer draws them.
  When the 1.1 offer is available, the row opens the composer's picker, as
  before. An assistant not yet moved off a Mac changes that Mac's model from
  the Lives on sheet.
- **Picker footer.** A cloud assistant's last line now reads
  `changesCloudAssistant` (the pinned export currently has "Cloud: this
  assistant"; the desktop's cloud-only export makes it "This assistant").
  The old `cloudAtumOnly` line said the cloud can use Atum's models only, and
  that is no longer true. The phone stops reading `cloudAtumOnly`, so the
  desktop can remove that key from its export.

No contract, fixture or export pin changes. The phone code drops the
per-Mac ordinal names and the Mac switch-back action on the card's Model
page. The Mac branch of the Lives on sheet's model picker stays, for an
assistant that still lives on a Mac.

## Tests

- `AssistantHomeDestinationTests.testTheCardModelPageEditsTheCloudEvenWhenMacsHaveChoices`:
  a 1.3 snapshot with three Mac choices gives the card the cloud and the
  cloud's model.
- `PhoneModelPickerCopyTests.testTheCloudAssistantLineNamesTheAssistantWithoutAnAtumOnlyLimit`:
  the cloud assistant's line comes from the pin in every locale, differs
  from the conversation line, and sets no "only" limit.
- `PhoneModelPickerCopyTests.testEveryKeyThePickerAsksForIsInThePinOrThePendingTable`
  now covers `changesCloudAssistant` in place of `cloudAtumOnly`.
