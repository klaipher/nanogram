# Age rating

Sources: Apple, age ratings update (2025): new levels 4+, 9+, 13+, 16+, 18+; questionnaire https://developer.apple.com/help/app-store-connect/reference/age-ratings/ ;
API https://developer.apple.com/documentation/appstoreconnectapi/ageratingdeclarations . Attribute names below follow the AgeRatingDeclaration resource as documented
(the docs page could not be fetched as plain text on 2026-11-14; confirm the names with a GET of the app's current declaration before the PATCH, and drop any attribute the GET does not return).

## Questionnaire answers

| Question | Answer |
|---|---|
| Cartoon or fantasy violence | None |
| Realistic violence | None |
| Prolonged graphic or sadistic realistic violence | None |
| Guns or other weapons | None |
| Sexual content or nudity | None (the app does not provide it; users can post it, see UGC below) |
| Graphic sexual content and nudity | None |
| Profanity or crude humor | None |
| Horror or fear themes | None |
| Alcohol, tobacco, drug use or references | None |
| Mature or suggestive themes | None |
| Medical or treatment information | None |
| Health or wellness topics | No |
| Simulated gambling | None |
| Real gambling | No |
| Contests | None |
| Loot boxes | No |
| Advertising in the app | Yes (Telegram's sponsored messages in large public channels; Telegram API terms 3.3 require every client to show them) |
| Messaging and chat | Yes |
| User-generated content | Yes |
| Unrestricted web access (in-app browser opens any URL) | Yes |
| Age assurance (the app verifies age) | No |

## Expected result

Telegram's official app is listed 13+ on the App Store (its page also lists Advertising, Messaging and Chat, User-Generated Content). With messaging, UGC, advertising and unrestricted web access answered Yes, Apple computes the rating itself; expect 16+ or 18+. The owner's own choice (the request said 17+, which the new scale maps to 18+): use 18+ because of open user content. This is not "matching the official client". If Apple computes 16+ and the owner wants 18+, set the override below. Korea override: NONE.

## API body

First `GET /v1/appInfos/{appInfoId}/ageRatingDeclaration` to get the declaration id, then:

```
PATCH /v1/ageRatingDeclarations/{id}
```

```json
{
  "data": {
    "type": "ageRatingDeclarations",
    "id": "{id}",
    "attributes": {
      "violenceCartoonOrFantasy": "NONE",
      "violenceRealistic": "NONE",
      "violenceRealisticProlongedGraphicOrSadistic": "NONE",
      "gunsOrOtherWeapons": "NONE",
      "sexualContentOrNudity": "NONE",
      "sexualContentGraphicAndNudity": "NONE",
      "profanityOrCrudeHumor": "NONE",
      "horrorOrFearThemes": "NONE",
      "alcoholTobaccoOrDrugUseOrReferences": "NONE",
      "matureOrSuggestiveThemes": "NONE",
      "medicalOrTreatmentInformation": "NONE",
      "healthOrWellnessTopics": false,
      "gamblingSimulated": "NONE",
      "gambling": false,
      "contests": "NONE",
      "lootBox": false,
      "advertising": true,
      "messagingAndChat": true,
      "userGeneratedContent": true,
      "unrestrictedWebAccess": true,
      "ageAssurance": false,
      "parentalControls": false,
      "ageRatingOverrideV2": "EIGHTEEN_PLUS",
      "koreaAgeRatingOverride": "NONE"
    }
  }
}
```

Notes: `parentalControls` follows the same GET-first rule as every other attribute: send it only if the GET returns it. `gamblingAndContests` and the older `ageRatingOverride` exist in older schemas; send them only if the GET returns them. Set `ageRatingOverrideV2` to `NONE` instead of `EIGHTEEN_PLUS` if the owner prefers Apple's computed value. Review notes (review-notes.md) explain the UGC controls Apple's guideline 1.2 asks for.
