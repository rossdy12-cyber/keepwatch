"""Builds "Paydays Apple Pay.shortcut" (unsigned). The GitHub workflow signs it on a Mac with
`shortcuts sign --mode anyone`, because iPhones only import signed shortcuts.

The shortcut asks for your private Paydays link when you add it, then for each Wallet transaction it is given:
POST {amount, merchant, raw} as JSON to that link and shows the answer as a notification.
Run it from a Shortcuts automation: Automation -> + -> Transaction -> choose the card -> Run Immediately ->
pick this shortcut.
"""
import plistlib
import sys

OBJ = "￼"  # where a variable sits inside a text field
DOWNLOAD_UUID = "6B1F9C55-2C1A-4E43-9D35-4E8A1C0D7A11"


def text(value):
    return {"Value": {"string": value, "attachmentsByRange": {}}, "WFSerializationType": "WFTextTokenString"}


def variable(attachment):
    return {"Value": {"string": OBJ, "attachmentsByRange": {"{0, 1}": attachment}}, "WFSerializationType": "WFTextTokenString"}


def input_property(name):
    return variable({"Type": "ExtensionInput",
                     "Aggrandizements": [{"Type": "WFPropertyVariableAggrandizement", "PropertyName": name}]})


body = {
    "Value": {"WFDictionaryFieldValueItems": [
        {"WFItemType": 0, "WFKey": text("amount"), "WFValue": input_property("Amount")},
        {"WFItemType": 0, "WFKey": text("merchant"), "WFValue": input_property("Merchant")},
        # The whole transaction as text, so Paydays can still find the amount if the fields above come through empty.
        {"WFItemType": 0, "WFKey": text("raw"), "WFValue": variable({"Type": "ExtensionInput"})},
    ]},
    "WFSerializationType": "WFDictionaryFieldValue",
}

workflow = {
    "WFWorkflowClientVersion": "2607.0.2",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4292093695, "WFWorkflowIconGlyphNumber": 61531},
    "WFWorkflowTypes": [],
    "WFWorkflowHasShortcutInputVariables": True,
    "WFWorkflowHasOutputFallback": False,
    "WFQuickActionSurfaces": [],
    "WFWorkflowInputContentItemClasses": [
        "WFAppContentItem", "WFAppEntityContentItem", "WFArticleContentItem", "WFContactContentItem",
        "WFDateContentItem", "WFEmailAddressContentItem", "WFFolderContentItem", "WFGenericFileContentItem",
        "WFImageContentItem", "WFiTunesProductContentItem", "WFLocationContentItem", "WFDCMapsLinkContentItem",
        "WFAVAssetContentItem", "WFPDFContentItem", "WFPhoneNumberContentItem", "WFRichTextContentItem",
        "WFSafariWebPageContentItem", "WFStringContentItem", "WFURLContentItem", "WFNumberContentItem",
        "WFDictionaryContentItem",
    ],
    "WFWorkflowImportQuestions": [{
        "ActionIndex": 0,
        "Category": "Parameter",
        "ParameterKey": "WFURL",
        "DefaultValue": "",
        "Text": "Paste your private Paydays link (Paydays → Pay & settings → Copy link).",
    }],
    "WFWorkflowActions": [
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
            "WFWorkflowActionParameters": {
                "UUID": DOWNLOAD_UUID,
                "WFURL": "",
                "WFHTTPMethod": "POST",
                "WFHTTPBodyType": "JSON",
                "WFJSONValues": body,
                "ShowHeaders": False,
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.notification",
            "WFWorkflowActionParameters": {
                "WFNotificationActionTitle": text("Paydays"),
                "WFNotificationActionBody": variable({"Type": "ActionOutput", "OutputUUID": DOWNLOAD_UUID,
                                                      "OutputName": "Contents of URL"}),
                "WFNotificationActionSound": False,
            },
        },
    ],
}

out = sys.argv[1] if len(sys.argv) > 1 else "unsigned.shortcut"
with open(out, "wb") as handle:
    plistlib.dump(workflow, handle, fmt=plistlib.FMT_BINARY)
print("wrote", out)
