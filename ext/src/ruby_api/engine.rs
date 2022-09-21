use super::{config::Config, root};
use crate::error;
use magnus::{function, method, Error, Module, Object, RString, Value, scan_args};
use wasmtime::Engine as EngineImpl;

#[derive(Clone)]
#[magnus::wrap(class = "Wasmtime::Engine")]
pub struct Engine {
    inner: EngineImpl,
}

impl Engine {
    pub fn new(args: &[Value]) -> Result<Self, Error> {
        let args = scan_args::scan_args::<(), (Option<&Config>,), (), (), (), ()>(args)?;
        let (config, ) = args.optional;
        let inner = match config {
            Some(config) => {
                EngineImpl::new(&config.get())
                    .map_err(|e| error!("{}", e))?
            }
            None => EngineImpl::default()
        };

        Ok(Self { inner })
    }

    pub fn get(&self) -> &EngineImpl {
        &self.inner
    }

    pub fn is_equal(&self, other: &Engine) -> bool {
        EngineImpl::same(self.get(), other.get())
    }

    pub fn precompile_module(&self, string: RString) -> Result<RString, Error> {
        self.inner.precompile_module(unsafe { string.as_slice() })
            .map(|bytes| RString::from_slice(&bytes))
            .map_err(|e| error!("{}", e.to_string()))
    }
}

pub fn init() -> Result<(), Error> {
    let class = root().define_class("Engine", Default::default())?;

    class.define_singleton_method("new", function!(Engine::new, -1))?;

    class.define_method("==", method!(Engine::is_equal, 1))?;
    class.define_method("precompile_module", method!(Engine::precompile_module, 1))?;

    Ok(())
}