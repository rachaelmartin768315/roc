#[derive(Debug, Clone)]
pub struct VecMap<K, V> {
    keys: Vec<K>,
    values: Vec<V>,
}

impl<K, V> Default for VecMap<K, V> {
    fn default() -> Self {
        Self {
            keys: Vec::new(),
            values: Vec::new(),
        }
    }
}

impl<K: PartialEq, V> VecMap<K, V> {
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            keys: Vec::with_capacity(capacity),
            values: Vec::with_capacity(capacity),
        }
    }

    pub fn len(&self) -> usize {
        debug_assert_eq!(self.keys.len(), self.values.len());
        self.keys.len()
    }

    pub fn is_empty(&self) -> bool {
        debug_assert_eq!(self.keys.len(), self.values.len());
        self.keys.is_empty()
    }

    pub fn swap_remove(&mut self, index: usize) -> (K, V) {
        let k = self.keys.swap_remove(index);
        let v = self.values.swap_remove(index);

        (k, v)
    }

    pub fn insert(&mut self, key: K, mut value: V) -> Option<V> {
        match self.keys.iter().position(|x| x == &key) {
            Some(index) => {
                std::mem::swap(&mut value, &mut self.values[index]);

                Some(value)
            }
            None => {
                self.keys.push(key);
                self.values.push(value);

                None
            }
        }
    }

    pub fn contains(&self, key: &K) -> bool {
        self.keys.contains(key)
    }

    pub fn remove(&mut self, key: &K) {
        match self.keys.iter().position(|x| x == key) {
            None => {
                // just do nothing
            }
            Some(index) => {
                self.swap_remove(index);
            }
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = (&K, &V)> {
        self.keys.iter().zip(self.values.iter())
    }

    pub fn values(&self) -> impl Iterator<Item = &V> {
        self.values.iter()
    }
}

impl<K: Ord, V> Extend<(K, V)> for VecMap<K, V> {
    #[inline(always)]
    fn extend<T: IntoIterator<Item = (K, V)>>(&mut self, iter: T) {
        let it = iter.into_iter();
        let hint = it.size_hint();

        match hint {
            (0, Some(0)) => {
                // done, do nothing
            }
            (1, Some(1)) | (2, Some(2)) => {
                for (k, v) in it {
                    self.insert(k, v);
                }
            }
            (_min, _opt_max) => {
                // TODO do this with sorting and dedup?
                for (k, v) in it {
                    self.insert(k, v);
                }
            }
        }
    }
}

impl<K, V> IntoIterator for VecMap<K, V> {
    type Item = (K, V);

    type IntoIter = IntoIter<K, V>;

    fn into_iter(self) -> Self::IntoIter {
        IntoIter {
            keys: self.keys.into_iter(),
            values: self.values.into_iter(),
        }
    }
}

pub struct IntoIter<K, V> {
    keys: std::vec::IntoIter<K>,
    values: std::vec::IntoIter<V>,
}

impl<K, V> Iterator for IntoIter<K, V> {
    type Item = (K, V);

    fn next(&mut self) -> Option<Self::Item> {
        match (self.keys.next(), self.values.next()) {
            (Some(k), Some(v)) => Some((k, v)),
            _ => None,
        }
    }
}
