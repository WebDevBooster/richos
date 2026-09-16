#![cfg(unix)]
use richos_core::{entity::{Entity, EntityId, EntityRegistry, RegistrySource}, repositories::connect, runtime::EngineRuntime};
use std::{path::PathBuf, collections::BTreeMap, process::Command};
struct Fixture(PathBuf);
impl Fixture {
 fn new() -> Self { let p=std::env::temp_dir().join(format!("richos repo fixture {}",uuid::Uuid::new_v4()));std::fs::create_dir(&p).unwrap();Self(std::fs::canonicalize(p).unwrap()) }
 fn runtime(&self)->EngineRuntime { EngineRuntime{root:self.0.clone(),git:"/usr/bin/git".into(),python:"/unused/python".into(),node:"/unused/node".into(),versions:BTreeMap::new()} }
 fn dir(&self,name:&str)->PathBuf {let p=self.0.join(name);std::fs::create_dir(&p).unwrap();p}
 fn registry(&self)->EntityRegistry {EntityRegistry::new(vec![Entity::new("alpha","Alpha",&[]).unwrap(),Entity::new("beta","Beta",&[]).unwrap()]).unwrap()}
}
impl Drop for Fixture {fn drop(&mut self){let _=std::fs::remove_dir_all(&self.0);}}
fn id(s:&str)->EntityId {EntityId::parse(s).unwrap()}
#[test]
fn two_repositories_persist_as_explicit_connections_and_leave_dirty_files_alone(){
 let f=Fixture::new();let one=f.dir("project one");let two=f.dir("project two");
 let (reg,first)=connect(&f.registry(),&id("alpha"),&one,true,&f.runtime(),&[]).unwrap();assert!(first.initialized);
 std::fs::write(one.join("local.txt"),"unrelated local edit").unwrap();
 let (reg,_)=connect(&reg,&id("alpha"),&two,true,&f.runtime(),&[]).unwrap();
 let (reg,again)=connect(&reg,&id("alpha"),&one,false,&f.runtime(),&[]).unwrap();assert!(!again.initialized);
 assert_eq!(std::fs::read_to_string(one.join("local.txt")).unwrap(),"unrelated local edit");
 reg.save(&f.0.join("entities.json")).unwrap();let loaded=EntityRegistry::load(&f.0.join("entities.json"));
 assert_eq!(loaded.source,RegistrySource::File);assert_eq!(loaded.registry,reg);
 assert_eq!(reg.get(&id("alpha")).unwrap().connected_repositories.len(),2);
 assert!(reg.get(&id("beta")).unwrap().connected_repositories.is_empty());
}
#[test]
fn refusal_never_initializes_nonempty_unselected_or_wrong_company_directories(){
 let f=Fixture::new();let empty=f.dir("empty");let full=f.dir("full");std::fs::write(full.join("keep"),"value").unwrap();
 assert!(connect(&f.registry(),&id("alpha"),&empty,false,&f.runtime(),&[]).is_err());
 assert!(connect(&f.registry(),&id("alpha"),&full,true,&f.runtime(),&[]).is_err());
 let reg=EntityRegistry::new(vec![Entity::try_new("alpha","Alpha",vec![]).unwrap(),Entity::try_new("beta","Beta",vec![empty.clone()]).unwrap()]).unwrap();
 assert!(connect(&reg,&id("alpha"),&empty,true,&f.runtime(),&[]).is_err());
 assert!(!empty.join(".git").exists());assert!(!full.join(".git").exists());
}
#[test]
fn nested_repositories_and_worktrees_are_not_adopted_as_main_checkouts(){
 let f=Fixture::new();let root=f.dir("main");let (reg,_)=connect(&f.registry(),&id("alpha"),&root,true,&f.runtime(),&[]).unwrap();
 let nested=root.join("nested");std::fs::create_dir(&nested).unwrap();
 assert!(connect(&reg,&id("alpha"),&nested,true,&f.runtime(),&[]).is_err());
 let linked=f.0.join("linked");assert!(Command::new("/usr/bin/git").current_dir(&root).args(["worktree","add","-q","-b","worker"]).arg(&linked).status().unwrap().success());
 assert!(connect(&reg,&id("alpha"),&linked,false,&f.runtime(),&[]).is_err());
}
#[test]
fn engine_storage_and_other_company_aliases_are_refused(){
 let f=Fixture::new();let root=f.dir("private app");
 assert!(connect(&f.registry(),&id("alpha"),&root,true,&f.runtime(),&[&root]).is_err());
 let alias=f.0.join("alias");std::os::unix::fs::symlink(&root,&alias).unwrap();
 let reg=EntityRegistry::new(vec![Entity::new("alpha","Alpha",&[]).unwrap(),Entity::try_new("beta","Beta",vec![alias]).unwrap()]).unwrap();
 assert!(connect(&reg,&id("alpha"),&root,true,&f.runtime(),&[]).is_err());assert!(!root.join(".git").exists());
}
#[test]
fn legacy_registry_loads_without_granting_repository_execution(){
 let f=Fixture::new();let p=f.0.join("legacy.json");std::fs::write(&p,r#"{"version":1,"entities":[{"id":"alpha","display_name":"Alpha","roots":["/fictional/repo"]}]}"#).unwrap();
 let original=std::fs::read(&p).unwrap();
 let loaded=EntityRegistry::load(&p);assert_eq!(loaded.source,RegistrySource::File);assert!(loaded.registry.get(&id("alpha")).unwrap().connected_repositories.is_empty());
 loaded.registry.save(&p).unwrap();
 let backups:Vec<_>=std::fs::read_dir(&f.0).unwrap().flatten().filter(|e|e.file_name().to_string_lossy().ends_with(".backup.json")).collect();
 assert_eq!(backups.len(),1);assert_eq!(std::fs::read(backups[0].path()).unwrap(),original);
}
