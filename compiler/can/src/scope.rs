use roc_collections::all::{MutSet, SendMap};
use roc_module::ident::{Ident, Lowercase};
use roc_module::symbol::{IdentIds, ModuleId, Symbol};
use roc_problem::can::RuntimeError;
use roc_region::all::{Loc, Region};
use roc_types::subs::{VarStore, Variable};
use roc_types::types::{Alias, AliasKind, Type};

use crate::abilities::AbilitiesStore;

#[derive(Clone, Debug, PartialEq)]
pub struct Scope {
    /// All the identifiers in scope, mapped to were they were defined and
    /// the Symbol they resolve to.
    idents: SendMap<Ident, (Symbol, Region)>,

    /// A cache of all the symbols in scope. This makes lookups much
    /// faster when checking for unused defs and unused arguments.
    symbols: SendMap<Symbol, Region>,

    /// The type aliases currently in scope
    pub aliases: SendMap<Symbol, Alias>,

    /// The abilities currently in scope, and their implementors.
    pub abilities_store: AbilitiesStore,

    /// The current module being processed. This will be used to turn
    /// unqualified idents into Symbols.
    home: ModuleId,
}

fn add_aliases(var_store: &mut VarStore) -> SendMap<Symbol, Alias> {
    use roc_types::solved_types::{BuiltinAlias, FreeVars};

    let solved_aliases = roc_types::builtin_aliases::aliases();
    let mut aliases = SendMap::default();

    for (symbol, builtin_alias) in solved_aliases {
        let BuiltinAlias { region, vars, typ } = builtin_alias;

        let mut free_vars = FreeVars::default();
        let typ = roc_types::solved_types::to_type(&typ, &mut free_vars, var_store);

        let mut variables = Vec::new();
        // make sure to sort these variables to make them line up with the type arguments
        let mut type_variables: Vec<_> = free_vars.unnamed_vars.into_iter().collect();
        type_variables.sort();
        for (loc_name, (_, var)) in vars.iter().zip(type_variables) {
            variables.push(Loc::at(loc_name.region, (loc_name.value.clone(), var)));
        }

        let alias = Alias {
            region,
            typ,
            lambda_set_variables: Vec::new(),
            recursion_variables: MutSet::default(),
            type_variables: variables,
            // TODO(opaques): replace when opaques are included in the stdlib
            kind: AliasKind::Structural,
        };

        aliases.insert(symbol, alias);
    }

    aliases
}

impl Scope {
    pub fn new(home: ModuleId, _var_store: &mut VarStore) -> Scope {
        Scope {
            home,
            idents: Symbol::default_in_scope(),
            symbols: SendMap::default(),
            aliases: SendMap::default(),
            // TODO(abilities): default abilities in scope
            abilities_store: AbilitiesStore::default(),
        }
    }

    pub fn new_with_aliases(home: ModuleId, var_store: &mut VarStore) -> Scope {
        Scope {
            home,
            idents: Symbol::default_in_scope(),
            symbols: SendMap::default(),
            aliases: add_aliases(var_store),
            // TODO(abilities): default abilities in scope
            abilities_store: AbilitiesStore::default(),
        }
    }

    pub fn idents(&self) -> impl Iterator<Item = (&Ident, &(Symbol, Region))> {
        self.idents.iter()
    }

    pub fn symbols(&self) -> impl Iterator<Item = (&Symbol, &Region)> {
        self.symbols.iter()
    }

    pub fn contains_ident(&self, ident: &Ident) -> bool {
        self.idents.contains_key(ident)
    }

    pub fn contains_symbol(&self, symbol: Symbol) -> bool {
        self.symbols.contains_key(&symbol)
    }

    pub fn num_idents(&self) -> usize {
        self.idents.len()
    }

    pub fn lookup(&self, ident: &Ident, region: Region) -> Result<Symbol, RuntimeError> {
        match self.idents.get(ident) {
            Some((symbol, _)) => Ok(*symbol),
            None => {
                let error = RuntimeError::LookupNotInScope(
                    Loc {
                        region,
                        value: ident.clone(),
                    },
                    self.idents.keys().map(|v| v.as_ref().into()).collect(),
                );

                Err(error)
            }
        }
    }

    pub fn lookup_alias(&self, symbol: Symbol) -> Option<&Alias> {
        self.aliases.get(&symbol)
    }

    /// Check if there is an opaque type alias referenced by `opaque_ref` referenced in the
    /// current scope. E.g. `$Age` must reference an opaque `Age` declared in this module, not any
    /// other!
    // TODO(opaques): $->@ in the above comment
    pub fn lookup_opaque_ref(
        &self,
        opaque_ref: &str,
        lookup_region: Region,
    ) -> Result<(Symbol, &Alias), RuntimeError> {
        debug_assert!(opaque_ref.starts_with('$'));
        let opaque = opaque_ref[1..].into();

        match self.idents.get(&opaque) {
            // TODO: is it worth caching any of these results?
            Some((symbol, decl_region)) => {
                if symbol.module_id() != self.home {
                    // The reference is to an opaque type declared in another module - this is
                    // illegal, as opaque types can only be wrapped/unwrapped in the scope they're
                    // declared.
                    return Err(RuntimeError::OpaqueOutsideScope {
                        opaque,
                        referenced_region: lookup_region,
                        imported_region: *decl_region,
                    });
                }

                match self.aliases.get(symbol) {
                    None => Err(self.opaque_not_defined_error(opaque, lookup_region, None)),

                    Some(alias) => match alias.kind {
                        // The reference is to a proper alias like `Age : U32`, not an opaque type!
                        AliasKind::Structural => Err(self.opaque_not_defined_error(
                            opaque,
                            lookup_region,
                            Some(alias.header_region()),
                        )),
                        // All is good
                        AliasKind::Opaque => Ok((*symbol, alias)),
                    },
                }
            }
            None => Err(self.opaque_not_defined_error(opaque, lookup_region, None)),
        }
    }

    fn opaque_not_defined_error(
        &self,
        opaque: Ident,
        lookup_region: Region,
        opt_defined_alias: Option<Region>,
    ) -> RuntimeError {
        let opaques_in_scope = self
            .idents()
            .filter(|(_, (sym, _))| {
                self.aliases
                    .get(sym)
                    .map(|alias| alias.kind)
                    .unwrap_or(AliasKind::Structural)
                    == AliasKind::Opaque
            })
            .map(|(v, _)| v.as_ref().into())
            .collect();

        RuntimeError::OpaqueNotDefined {
            usage: Loc::at(lookup_region, opaque),
            opaques_in_scope,
            opt_defined_alias,
        }
    }

    /// Introduce a new ident to scope.
    ///
    /// Returns Err if this would shadow an existing ident, including the
    /// Symbol and Region of the ident we already had in scope under that name.
    ///
    /// If this ident shadows an existing one, a new ident is allocated for the shadow. This is
    /// done so that all identifiers have unique symbols, which is important in particular when
    /// we generate code for value identifiers.
    /// If this behavior is undesirable, use [`Self::introduce_without_shadow_symbol`].
    pub fn introduce(
        &mut self,
        ident: Ident,
        exposed_ident_ids: &IdentIds,
        all_ident_ids: &mut IdentIds,
        region: Region,
    ) -> Result<Symbol, (Region, Loc<Ident>, Symbol)> {
        match self.idents.get(&ident) {
            Some(&(_, original_region)) => {
                let shadow = Loc {
                    value: ident.clone(),
                    region,
                };

                let ident_id = all_ident_ids.add(ident.clone());
                let symbol = Symbol::new(self.home, ident_id);

                self.symbols.insert(symbol, region);
                self.idents.insert(ident, (symbol, region));

                Err((original_region, shadow, symbol))
            }
            None => Ok(self.commit_introduction(ident, exposed_ident_ids, all_ident_ids, region)),
        }
    }

    /// Like [Self::introduce], but does not introduce a new symbol for the shadowing symbol.
    pub fn introduce_without_shadow_symbol(
        &mut self,
        ident: Ident,
        exposed_ident_ids: &IdentIds,
        all_ident_ids: &mut IdentIds,
        region: Region,
    ) -> Result<Symbol, (Region, Loc<Ident>)> {
        match self.idents.get(&ident) {
            Some(&(_, original_region)) => {
                let shadow = Loc {
                    value: ident.clone(),
                    region,
                };
                Err((original_region, shadow))
            }
            None => Ok(self.commit_introduction(ident, exposed_ident_ids, all_ident_ids, region)),
        }
    }

    /// Like [Self::introduce], but handles the case of when an ident matches an ability member
    /// name. In such cases a new symbol is created for the ident (since it's expected to be a
    /// specialization of the ability member), but the ident is not added to the ident->symbol map.
    ///
    /// If the ident does not match an ability name, the behavior of this function is exactly that
    /// of `introduce`.
    #[allow(clippy::type_complexity)]
    pub fn introduce_or_shadow_ability_member(
        &mut self,
        ident: Ident,
        exposed_ident_ids: &IdentIds,
        all_ident_ids: &mut IdentIds,
        region: Region,
    ) -> Result<(Symbol, Option<Symbol>), (Region, Loc<Ident>, Symbol)> {
        match self.idents.get(&ident) {
            Some(&(original_symbol, original_region)) => {
                let shadow_ident_id = all_ident_ids.add(ident.clone());
                let shadow_symbol = Symbol::new(self.home, shadow_ident_id);

                self.symbols.insert(shadow_symbol, region);

                if self.abilities_store.is_ability_member_name(original_symbol) {
                    self.abilities_store
                        .register_specializing_symbol(shadow_symbol, original_symbol);
                    // Add a symbol for the shadow, but don't re-associate the member name.
                    Ok((shadow_symbol, Some(original_symbol)))
                } else {
                    // This is an illegal shadow.
                    let shadow = Loc {
                        value: ident.clone(),
                        region,
                    };

                    self.idents.insert(ident, (shadow_symbol, region));

                    Err((original_region, shadow, shadow_symbol))
                }
            }
            None => {
                let new_symbol =
                    self.commit_introduction(ident, exposed_ident_ids, all_ident_ids, region);
                Ok((new_symbol, None))
            }
        }
    }

    fn commit_introduction(
        &mut self,
        ident: Ident,
        exposed_ident_ids: &IdentIds,
        all_ident_ids: &mut IdentIds,
        region: Region,
    ) -> Symbol {
        // If this IdentId was already added previously
        // when the value was exposed in the module header,
        // use that existing IdentId. Otherwise, create a fresh one.
        let ident_id = match exposed_ident_ids.get_id(&ident) {
            Some(ident_id) => ident_id,
            None => all_ident_ids.add(ident.clone()),
        };

        let symbol = Symbol::new(self.home, ident_id);

        self.symbols.insert(symbol, region);
        self.idents.insert(ident, (symbol, region));

        symbol
    }

    /// Ignore an identifier.
    ///
    /// Used for record guards like { x: Just _ }
    pub fn ignore(&mut self, ident: Ident, all_ident_ids: &mut IdentIds) -> Symbol {
        let ident_id = all_ident_ids.add(ident);
        Symbol::new(self.home, ident_id)
    }

    /// Import a Symbol from another module into this module's top-level scope.
    ///
    /// Returns Err if this would shadow an existing ident, including the
    /// Symbol and Region of the ident we already had in scope under that name.
    pub fn import(
        &mut self,
        ident: Ident,
        symbol: Symbol,
        region: Region,
    ) -> Result<(), (Symbol, Region)> {
        match self.idents.get(&ident) {
            Some(shadowed) => Err(*shadowed),
            None => {
                self.symbols.insert(symbol, region);
                self.idents.insert(ident, (symbol, region));

                Ok(())
            }
        }
    }

    pub fn add_alias(
        &mut self,
        name: Symbol,
        region: Region,
        vars: Vec<Loc<(Lowercase, Variable)>>,
        typ: Type,
        kind: AliasKind,
    ) {
        let alias = create_alias(name, region, vars, typ, kind);
        self.aliases.insert(name, alias);
    }

    pub fn contains_alias(&mut self, name: Symbol) -> bool {
        self.aliases.contains_key(&name)
    }
}

pub fn create_alias(
    name: Symbol,
    region: Region,
    vars: Vec<Loc<(Lowercase, Variable)>>,
    typ: Type,
    kind: AliasKind,
) -> Alias {
    let roc_types::types::VariableDetail {
        type_variables,
        lambda_set_variables,
        recursion_variables,
    } = typ.variables_detail();

    debug_assert!({
        let mut hidden = type_variables;

        for loc_var in vars.iter() {
            hidden.remove(&loc_var.value.1);
        }

        if !hidden.is_empty() {
            panic!(
                "Found unbound type variables {:?} \n in type alias {:?} {:?} : {:?}",
                hidden, name, &vars, &typ
            )
        }

        true
    });

    let lambda_set_variables: Vec<_> = lambda_set_variables
        .into_iter()
        .map(|v| roc_types::types::LambdaSet(Type::Variable(v)))
        .collect();

    Alias {
        region,
        type_variables: vars,
        lambda_set_variables,
        recursion_variables,
        typ,
        kind,
    }
}
