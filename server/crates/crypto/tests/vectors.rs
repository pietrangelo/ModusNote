//! The golden vectors of `server/vectors`, written by the Dart domain: the
//! server must give every case the same verdict as the clients.

use std::collections::BTreeMap;

use crypto::{StrictEd25519, blake2b_256};
use ledger::{Credential, KeyBundle, MemberKey, Record, Refused, VerifiedLedger, signable_request};
use serde_json::Value;

fn vectors(name: &str) -> Vec<Value> {
    let path = format!("{}/../../vectors/{name}", env!("CARGO_MANIFEST_DIR"));
    let json: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    json["cases"].as_array().unwrap().clone()
}

fn bytes(value: &Value) -> Vec<u8> {
    hex::decode(value.as_str().unwrap()).unwrap()
}

/// The log as the server takes it: the first record founds it, each later
/// one must extend it; the first refusal stops.
fn verify(records: &[Value]) -> Option<VerifiedLedger> {
    let mut ledger: Option<VerifiedLedger> = None;
    for wire in records {
        let step = Record::parse(&bytes(wire)).map_err(Refused::from).and_then(|record| match &mut ledger {
            None => VerifiedLedger::found(record, &StrictEd25519).map(|found| ledger = Some(found)),
            Some(ledger) => ledger.extend(record, &StrictEd25519),
        });
        if step.is_err() {
            break;
        }
    }
    ledger
}

#[test]
fn ledger_vectors() {
    let cases = vectors("ledger.json");
    assert!(cases.len() > 20);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let ledger = verify(case["records"].as_array().unwrap());
        let accepted = ledger.as_ref().map_or(0, VerifiedLedger::len);
        assert_eq!(accepted as u64, case["accepted"].as_u64().unwrap(), "{name}: records accepted");
        let Some(ledger) = ledger else { continue };
        let members: BTreeMap<MemberKey, u8> =
            ledger.workspace().members.iter().map(|(key, role)| (*key, role.wire())).collect();
        let expected: BTreeMap<MemberKey, u8> = case["members"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| (MemberKey::parse_hex(m["key"].as_str().unwrap()).unwrap(), m["role"].as_u64().unwrap() as u8))
            .collect();
        assert_eq!(members, expected, "{name}: members");
        assert_eq!(u64::from(ledger.workspace().epoch), case["epoch"].as_u64().unwrap(), "{name}: epoch");
        for (i, bundle) in case["bundles"].as_array().unwrap().iter().enumerate() {
            let valid = KeyBundle::parse(&bytes(&bundle["bundle"]))
                .map_err(Refused::from)
                .and_then(|bundle| ledger.check_bundle(&bundle, &StrictEd25519))
                .is_ok();
            assert_eq!(valid, bundle["valid"].as_bool().unwrap(), "{name}: bundle {i}");
        }
    }
}

#[test]
fn request_vectors() {
    let cases = vectors("requests.json");
    assert!(cases.len() > 5);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let credential = Credential::parse(case["authorization"].as_str().unwrap()).expect(name);
        let signable = signable_request(
            case["method"].as_str().unwrap(),
            case["path"].as_str().unwrap(),
            credential.millis,
            &credential.nonce,
            &blake2b_256(&bytes(&case["body"])),
        )
        .unwrap();
        assert_eq!(signable, bytes(&case["signable"]), "{name}: signable");
        let valid = ledger::SignatureCheck::verifies(&StrictEd25519, &credential.key, &signable, &credential.signature);
        assert_eq!(valid, case["valid"].as_bool().unwrap(), "{name}: valid");
    }
}
