//! Desktop adapter: use the existing scoped conversation, streaming and
//! cancellation machinery with the portable run controller.
use crate::cognition::{Cognition, CognitionError, TurnItem};
use crate::entity::ThreadBinding;
use crate::run::{Check, RunHost, RunPlan, RunSnapshot, TaskSpec};
use crate::run_host::{verify_command, CognitionRunHost};
use crate::spine::Spine;
pub const EVENT_RUN_UPDATED: &str = "rich://run-updated";
use std::path::Path;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

pub struct SpineRunHost<'a> {
    pub spine: &'a mut Spine,
    pub binding: ThreadBinding,
    pub worker: Option<Box<dyn Cognition>>,
    pub pause: Arc<AtomicBool>,
    pub on_update: Option<Box<dyn FnMut(&RunSnapshot) + 'a>>,
}

struct ScopedLease<'a> {
    spine: &'a mut Spine,
    binding: &'a ThreadBinding,
}
impl Cognition for ScopedLease<'_> {
    fn prepare_managed(&self, workspace: &Path) -> Result<(), CognitionError> {
        self.spine.prepare_managed_lease(workspace)
    }
    fn session_id(&self) -> &str {
        self.spine.lease_session_id().unwrap_or("")
    }
    fn reprime(&mut self, _: &str, _: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        Err(CognitionError::Protocol(
            "The spine owns re-priming.".into(),
        ))
    }
    fn prompt(
        &mut self,
        text: &str,
        _: &mut dyn FnMut(TurnItem),
    ) -> Result<String, CognitionError> {
        self.spine
            .submit_run_prompt(self.binding, text)
            .map_err(|e| CognitionError::Io(e.to_string()))
    }
    fn cancel_handle(&self) -> Option<Arc<dyn crate::steering::TurnCancel>> {
        self.spine.run_cancel_handle()
    }
}

impl RunHost for SpineRunHost<'_> {
    fn permission_context(&mut self, context: crate::permission::Context) -> Result<(), String> {
        if self.worker.is_none() {
            self.worker = Some(Box::new(crate::native::NativeCognition::start_managed(
                &crate::native::resolve_claude_bin(), &context.workspace).map_err(|e| e.to_string())?));
        }
        self.worker.as_mut().unwrap().set_managed_permission_context(context).map_err(|e| e.to_string())
    }

    fn updated(&mut self, snapshot: &RunSnapshot) {
        if let Some(callback) = &mut self.on_update {
            callback(snapshot);
        }
    }
    fn execute(
        &mut self,
        plan: &RunPlan,
        task: &TaskSpec,
        previous: &[String],
    ) -> Result<(), String> {
        self.spine
            .ledger()
            .verify_binding(&self.binding)
            .map_err(|e| e.to_string())?;
        let entity = self
            .spine
            .entity_registry()
            .resolve_root(&plan.workspace)
            .map_err(|e| e.to_string())?;
        if &entity.id != self.binding.entity_id() {
            return Err("The run workspace belongs to a different entity.".into());
        }
        let worker: Box<dyn Cognition> = match self.worker.take() {
            Some(worker) => worker,
            None => Box::new(
                crate::native::NativeCognition::start_managed(
                    &crate::native::resolve_claude_bin(),
                    &plan.workspace,
                )
                .map_err(|e| e.to_string())?,
            ),
        };
        worker
            .prepare_managed(&plan.workspace)
            .map_err(|e| e.to_string())?;
        let previous_lease = self.spine.take_run_lease(worker);
        let result = {
            let mut lease = ScopedLease {
                spine: self.spine,
                binding: &self.binding,
            };
            let mut sink = |_: TurnItem<'_>| {};
            CognitionRunHost {
                cognition: &mut lease,
                on_item: &mut sink,
                pause: self.pause.clone(),
            }
            .execute(plan, task, previous)
        };
        self.spine.restore_run_lease(previous_lease);
        // User steering and lease rotation are between attempts, never inside
        // the watchdog for the attempt that just ended.
        self.spine
            .finish_run_boundary(&self.binding)
            .map_err(|e| e.to_string())?;
        result
    }

    fn verify(&mut self, workspace: &Path, check: &Check) -> Result<String, String> {
        self.spine
            .ledger()
            .verify_binding(&self.binding)
            .map_err(|e| e.to_string())?;
        verify_command(workspace, check, &self.pause)
    }
    fn paused(&self) -> bool {
        self.pause.load(Ordering::SeqCst)
    }
}
