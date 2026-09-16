    #[test]
    fn audit_damaged_worker_evidence_bypasses_turn_end_fence() {
        use crate::cognition::Cognition;
        use std::collections::BTreeMap;
        for damaged in [false, true] {
            let script = write_script("audit-unsettled", r#"
read -r init
printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{}}}'
read -r prompt
printf '%s\n' '{"type":"result","stop_reason":"end_turn"}'
read -r keep_alive
"#);
            let mut cognition = NativeCognition::start(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).unwrap();
            let root = script.parent().unwrap().join("state");
            let folder = root.join("evidence").join(&cognition.session_id);
            std::fs::create_dir_all(&folder).unwrap();
            let mut log = serde_json::json!({"schema":1,"callback":{"session_id":cognition.session_id,"hook_event_name":"SubagentStart","agent_id":"still-running"}}).to_string()+"\n";
            if damaged { log.push_str("{\"schema\":"); }
            std::fs::write(folder.join("callbacks.jsonl"), log).unwrap();
            let state = crate::app_workers::status(&root, Some(&cognition.session_id));
            cognition.engine_profile = Some(crate::engine_profile::EngineProfile {
                engine: root.clone(), coordination: root.clone(), plugin: root.clone(), state: root.clone(),
                runtime: crate::runtime::EngineRuntime {root: root.clone(), python:"/usr/bin/python3".into(), node:"/usr/bin/false".into(), git:"/usr/bin/git".into(),versions:BTreeMap::new()},
                work_scope:None, permissions:Default::default()
            });
            let result = cognition.prompt("Synthetic audit turn", &mut |_| {});
            let provider_alive = cognition.client.child.try_wait().unwrap().is_none();
            println!("AUDIT damaged={damaged}, liveness_unknown={}, unattributed={:?}, result={result:?}, provider_alive={provider_alive}", state.liveness_unknown,state.unattributed);
            if damaged { assert_eq!(result.unwrap(),"end_turn"); assert!(provider_alive); }
            else { assert!(result.is_err()); assert!(!provider_alive); }
        }
    }
