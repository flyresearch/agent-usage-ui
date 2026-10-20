//! Application-owned storage only. Native provider credential locations remain
//! their providers' locations; the fork must not overwrite Syrtis-owned state.
pub(crate) fn independent() -> bool {
    std::env::var("AGENT_USAGE_NATIVE_RUNTIME").as_deref() == Ok("1")
}
pub(crate) fn directory_for(independent: bool) -> &'static str {
    if independent {
        "org.flyresearch.agentusage/native-history"
    } else {
        "com.nyanako.tokenbar"
    }
}
pub(crate) fn directory() -> &'static str {
    directory_for(independent())
}
pub(crate) fn captured_service_for(independent: bool) -> &'static str {
    if independent {
        "org.flyresearch.agentusage.antigravity-account"
    } else {
        "com.nyanako.tokenbar.antigravity-account"
    }
}
pub(crate) fn captured_service() -> &'static str {
    captured_service_for(independent())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_fork_does_not_share_application_storage_or_captured_accounts() {
        assert_eq!(directory_for(false), "com.nyanako.tokenbar");
        assert_eq!(
            directory_for(true),
            "org.flyresearch.agentusage/native-history"
        );
        assert_ne!(captured_service_for(false), captured_service_for(true));
    }
    #[test]
    fn process_namespace_reaches_the_production_history_path() {
        let enabled=std::env::var("AGENT_USAGE_NATIVE_RUNTIME").as_deref()==Ok("1");
        assert_eq!(independent(),enabled);
        let expected = if enabled {
            "org.flyresearch.agentusage/native-history"
        } else {
            "com.nyanako.tokenbar"
        };
        let path = crate::agent_quota_history::production_history_path().unwrap();
        assert!(path.parent().unwrap().ends_with(expected));
    }
}
