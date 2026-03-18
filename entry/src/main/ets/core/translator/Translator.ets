export interface Translator<S, T> {
  translate(source: S): T
}
