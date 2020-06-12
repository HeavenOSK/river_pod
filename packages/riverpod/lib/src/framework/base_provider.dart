part of 'framework.dart';

// ignore: one_member_abstracts
abstract class ProviderListenable<T> {
  ProviderSubscription addLazyListener(
    ProviderStateOwner owner, {
    @required void Function() mayHaveChanged,
    @required void Function(T value) onChange,
  });
}

class ProviderSelector<Input, Output> implements ProviderListenable<Output> {
  ProviderSelector._(
    this._provider,
    this._selector,
  );

  final ProviderBase<ProviderDependencyBase, Input> _provider;
  final Output Function(Input) _selector;

  @override
  ProviderSubscription addLazyListener(
    ProviderStateOwner owner, {
    void Function() mayHaveChanged,
    void Function(Output value) onChange,
  }) {
    final state = owner._readProviderState(_provider);
    return SelectorSubscription._(
      state,
      _selector,
      mayHaveChanged,
      onChange,
    );
  }
}

abstract class ProviderSubscription {
  ProviderSubscription._();

  bool flush();
  void close();
}

class _ProviderSubscription<T> implements ProviderSubscription {
  _ProviderSubscription(
    this._providerState,
    this._onChange,
    this._entry,
  ) : _lastNotificationCount = _providerState._notificationCount;

  int _lastNotificationCount;
  final ProviderStateBase<ProviderDependencyBase, T,
      ProviderBase<ProviderDependencyBase, T>> _providerState;
  final void Function(T value) _onChange;
  final LinkedListEntry _entry;

  @override
  bool flush() {
    if (_entry.list == null) {
      return false;
    }
    _providerState.flush();
    assert(
      !_providerState.dirty,
      'flush must either cancel or confirm the notification',
    );
    if (_providerState._notificationCount != _lastNotificationCount) {
      _lastNotificationCount = _providerState._notificationCount;

      assert(() {
        debugNotifyListenersDepthLock = _providerState._debugDepth;
        return true;
      }(), '');
      _runUnaryGuarded(_onChange, _providerState.state);
      assert(() {
        debugNotifyListenersDepthLock = -1;
        return true;
      }(), '');
      return true;
    }
    return false;
  }

  @override
  void close() => _entry.unlink();
}

class SelectorSubscription<Input, Output> implements ProviderSubscription {
  SelectorSubscription._(
    ProviderStateBase<ProviderDependencyBase, Input,
            ProviderBase<ProviderDependencyBase, Input>>
        providerState,
    this._selector,
    void Function() mayHaveChanged,
    this._onOutputChange,
  ) {
    _providerSubscription = providerState.addLazyListener(
      mayHaveChanged: mayHaveChanged,
      onChange: _onInputChange,
    );
  }

  ProviderSubscription _providerSubscription;

  final void Function(Output value) _onOutputChange;
  bool _isFirstInputOnChange = true;
  Input _input;
  Output _lastOutput;
  Output Function(Input) _selector;

  void updateSelector(ProviderListenable subscription) {
    _selector = (subscription as ProviderSelector<Input, Output>)._selector;
    _providerSubscription.flush();
    _onOutputChange(_lastOutput = _selector(_input));
  }

  void _onInputChange(Input input) {
    _input = input;
    if (_isFirstInputOnChange) {
      _isFirstInputOnChange = false;
      _onOutputChange(_lastOutput = _selector(_input));
    }
  }

  @override
  bool flush() {
    if (_providerSubscription.flush()) {
      final newOutput = _selector(_input);
      if (!const DeepCollectionEquality().equals(_lastOutput, newOutput)) {
        _onOutputChange(_lastOutput = newOutput);
        return true;
      }
    }
    return false;
  }

  @override
  void close() => _providerSubscription.close();
}

/// A base class for all providers.
///
/// Do not extend or implement.
@immutable
@optionalTypeArgs
abstract class ProviderBase<Dependency extends ProviderDependencyBase,
    Result extends Object> implements ProviderListenable<Result> {
  /// Allows specifying a name.
  // ignore: prefer_const_constructors_in_immutables, the canonalisation of constants is unsafe for providers.
  ProviderBase(this.name);

  @visibleForOverriding
  ProviderStateBase<Dependency, Result, ProviderBase<Dependency, Result>>
      createState();

  /// A custom label for the provider.
  ///
  /// Specifying a name has multiple uses:
  /// - It makes devtools and logging more readable
  /// - It can be used as a serialisable unique identifier for state serialisation/deserialisation.
  final String name;

  @override
  ProviderSubscription addLazyListener(
    ProviderStateOwner owner, {
    @required void Function() mayHaveChanged,
    @required void Function(Result value) onChange,
  }) {
    return owner
        ._readProviderState(this)
        .addLazyListener(mayHaveChanged: mayHaveChanged, onChange: onChange);
  }

  VoidCallback watchOwner(
    ProviderStateOwner owner,
    void Function(Result value) onChange,
  ) {
    ProviderSubscription sub;

    sub = addLazyListener(
      owner,
      mayHaveChanged: () => sub.flush(),
      onChange: onChange,
    );

    return sub.close;
  }

  ProviderListenable<Selected> select<Selected>(
    Selected Function(Result value) selector,
  ) {
    return ProviderSelector._(this, selector);
  }

  @override
  String toString() {
    return '$runtimeType#$hashCode(name: $name)';
  }
}

/// Implementation detail of how the state of a provider is stored.
// TODO: prefix internal methods with $ and public methods without
@optionalTypeArgs
abstract class ProviderStateBase<Dependency extends ProviderDependencyBase,
    Result extends Object, P extends ProviderBase<Dependency, Result>> {
  P _provider;

  /// The current [ProviderBase] associated with this state.
  ///
  /// It may change if the provider is overriden, and the override changes,
  /// in which case it will call [didUpdateProvider].
  @protected
  @visibleForTesting
  P get provider => _provider;

  /// The raw unmodified provider before applying [ProviderOverride].
  ProviderBase<ProviderDependencyBase, Object> _origin;

  int _notificationCount = 0;

  // Initialised to true to ignore calls to markNeedNotifyListeners inside initState
  var _dirty = true;

  /// Whether this provider was marked as needing to notify its listeners.
  ///
  /// See also [markMayHaveChanged].
  bool get dirty => _dirty;

  var _mounted = true;

  /// Whether this provider was disposed or not.
  ///
  /// See also [ProviderReference.mounted].
  bool get mounted => _mounted;

  /// The value currently exposed.
  ///
  /// All modifications to this property should induce a call to [markMayHaveChanged]
  /// followed by [notifyChanged].
  @protected
  Result get state;

  /// All the states that depends on this provider.
  final _dependents = HashSet<ProviderStateBase>();

  @visibleForTesting
  Set<ProviderStateBase> get debugDependents {
    Set<ProviderStateBase> result;
    assert(() {
      result = {..._dependents};
      return true;
    }(), '');
    return result;
  }

  /// All the [ProviderStateBase]s that this provider depends on.
  final _providerStateDependencies = HashSet<ProviderStateBase>();

  /// A cache of the [ProviderDependencyBase] associated to the dependencies
  /// listed by [_providerStateDependencies].
  ///
  /// This avoid having to call [createProviderDependency] again when this
  /// state already depends on a provider.
  Map<ProviderBase, ProviderDependencyBase> _providerDependencysCache;

  /// An implementation detail of [CircularDependencyError].
  ///
  /// This handles the case where [ProviderReference.dependOn] is called
  /// synchronously during the creation of the provider.
  ProviderBase _debugInitialDependOnRequest;

  /// The exception thrown inside [initState], if any.
  ///
  /// If [_error] is not `null`, this disable all functionalities of the provider
  /// and trying to read the provider will result in throwing this object again.
  Object _error;

  ProviderStateOwner _owner;

  /// The [ProviderStateOwner] that keeps a reference to this state.
  ProviderStateOwner get owner => _owner;

  /// The list of listeners to [ProviderReference.onDispose].
  DoubleLinkedQueue<VoidCallback> _onDisposeCallbacks;

  /// The listeners of this provider (using [ProviderBase.watchOwner]).
  LinkedList<_LinkedListEntry<void Function()>> _mayHaveChangedListeners;

  /// Whether this provider is listened or not.
  // TODO: factor [createDependency]
  bool get $hasListeners => _mayHaveChangedListeners?.isNotEmpty ?? false;

  int get _debugDepth {
    int result;
    assert(() {
      final states =
          _owner._visitStatesInReverseOrder().toList().reversed.toList();
      result = states.indexOf(this);
      return true;
    }(), '');
    return result;
  }

  void initState();

  /// Creates the object returned by [ProviderReference.dependOn].
  Dependency createProviderDependency();

  /// Life-cycle for when [provider] was replaced with a new one.
  ///
  /// This typically happen on [ProviderStateOwner.updateOverrides] call with new
  /// overrides.
  @mustCallSuper
  @protected
  void didUpdateProvider(P oldProvider) {}

  /// The implementation of [ProviderReference.dependOn].
  T dependOn<T extends ProviderDependencyBase>(
    ProviderBase<T, Object> provider,
  ) {
    if (!mounted) {
      throw StateError(
        '`dependOn` was called on a state that is already disposed',
      );
    }
    // verify that we are not in a stack overflow of dependOn calls.
    assert(() {
      if (_debugInitialDependOnRequest == provider) {
        throw CircularDependencyError._();
      }
      _debugInitialDependOnRequest ??= provider;
      return true;
    }(), '');

    _providerDependencysCache ??= {};
    try {
      return _providerDependencysCache.putIfAbsent(provider, () {
        final targetProviderState = _owner._readProviderState(provider);

        // verify that the new dependency doesn't depend on this provider.
        assert(() {
          void recurs(ProviderStateBase state) {
            if (state == this) {
              throw CircularDependencyError._();
            }
            state._providerStateDependencies.forEach(recurs);
          }

          targetProviderState._providerStateDependencies.forEach(recurs);
          return true;
        }(), '');

        _providerStateDependencies.add(targetProviderState);
        targetProviderState._dependents.add(this);
        final targetProviderValue =
            targetProviderState.createProviderDependency();
        onDispose(() {
          targetProviderState._dependents.remove(this);
          targetProviderValue.dispose();
        });

        return targetProviderValue;
      }) as T;
    } finally {
      assert(() {
        if (_debugInitialDependOnRequest == provider) {
          _debugInitialDependOnRequest = null;
        }
        return true;
      }(), '');
    }
  }

  /// Implementation of [ProviderReference.onDispose].
  void onDispose(VoidCallback cb) {
    if (!mounted) {
      throw StateError(
        '`onDispose` was called on a state that is already disposed',
      );
    }
    _onDisposeCallbacks ??= DoubleLinkedQueue();
    _onDisposeCallbacks.add(cb);
  }

  ProviderSubscription addLazyListener({
    @required void Function() mayHaveChanged,
    @required void Function(Result value) onChange,
  }) {
    assert(() {
      debugNotifyListenersDepthLock = _debugDepth;
      return true;
    }(), '');
    _runUnaryGuarded(onChange, state);
    assert(() {
      debugNotifyListenersDepthLock = -1;
      return true;
    }(), '');

    _mayHaveChangedListeners ??= LinkedList();
    final mayHaveChangedEntry = _LinkedListEntry(mayHaveChanged);
    _mayHaveChangedListeners.add(mayHaveChangedEntry);

    return _ProviderSubscription(
      this,
      onChange,
      mayHaveChangedEntry,
    );
  }

  @visibleForOverriding
  void flush() {
    if (_dirty) {
      notifyChanged();
    }
  }

  void notifyChanged() {
    assert(_dirty, 'must call markMayHaveChanged before notifyChanged');
    if (!_mounted) {
      throw StateError(
        'Cannot notify listeners of a provider after if was dispose',
      );
    }
    _dirty = false;
    _notificationCount++;
    _owner._reportChanged(_origin, state);
  }

  void cancelChangeNotification() {
    assert(_dirty, 'must call cancelChangeNotification before notifyChanged');
    _dirty = false;
  }

  void markMayHaveChanged() {
    if (notifyListenersLock != null && notifyListenersLock != this) {
      throw StateError(
        'Cannot mark providers as dirty while initializing/disposing another provider',
      );
    }
    assert(
      debugNotifyListenersDepthLock < _debugDepth,
      'Cannot mark `$provider` as dirty from `$debugNotifyListenersDepthLock` as the latter depends on it.',
    );
    if (_error != null) {
      throw StateError(
        'Cannot trigger updates on a provider that threw during creation',
      );
    }
    if (!_mounted) {
      throw StateError(
        'Cannot notify listeners of a provider after if was dispose',
      );
    }
    if (!_dirty) {
      _dirty = true;

      if (_mayHaveChangedListeners != null) {
        for (final mayHaveChanged in _mayHaveChangedListeners) {
          // TODO guard
          mayHaveChanged.value();
        }
      }
    }
  }

  /// Life-cycle for when the provider state is destroyed.
  ///
  /// It triggers [ProviderReference.onDispose]
  @mustCallSuper
  void dispose() {
    _mounted = false;
    if (_onDisposeCallbacks != null) {
      _onDisposeCallbacks.forEach(_runGuarded);
    }

    if (_owner._observers != null) {
      for (final observer in _owner._observers) {
        _runUnaryGuarded(observer.didDisposeProvider, _origin);
      }
    }
  }

  @override
  String toString() {
    return 'ProviderState<$Result>(provider: $provider)';
  }
}

/// A base class for providers that do not dispose themselves naturally.
///
/// What this means is, once the provider was read once, even if the value
/// is no longer used, the provider still will not be destroyed.
///
/// The main reason why this would be desired is, it allows simplifying
/// the process of reading the provider:
/// Since the provider is never destroyed, we can safely read the provider
/// without "listening" to it.
///
/// This allows implementing methods like [readOwner], or if using Flutter
/// do `provider.read(BuildContext)`.
///
/// Similarly, since these providers are never disposed, they can only be
/// overriden by providers that too are never disposed.
/// Otherwise methods like [readOwner] would have an unknown behavior.
abstract class AlwaysAliveProvider<Dependency extends ProviderDependencyBase,
        Result> extends ProviderBase<Dependency, Result>
    implements ProviderOverride {
  /// Creates an [AlwaysAliveProvider] and allows specifing a [name].
  AlwaysAliveProvider(String name) : super(name);

  @override
  ProviderBase get _provider => this;

  @override
  ProviderBase<Dependency, Result> get _origin => this;

  /// Reads a provider without listening to it and returns the currently
  /// exposed value.
  ///
  /// ```dart
  /// final greetingProvider = Provider((_) => 'Hello world');
  ///
  /// void main() {
  ///   final owner = ProviderStateOwner();
  ///
  ///   print(greetingProvider.readOwner(owner)); // Hello World
  /// }
  /// ```
  Result readOwner(ProviderStateOwner owner) {
    return owner._readProviderState(this).state;
  }

  /// Combined with [ProviderStateOwner] (or `ProviderScope` if you are using Flutter),
  /// allows overriding the behavior of this provider for a part of the application.
  ///
  /// A use-case could be for testing, to override the implementation of a
  /// `Repository` class with a fake implementation.
  ///
  /// In a Flutter application, this would look like:
  ///
  /// ```dart
  /// final repositoryProvider = Provider((_) => Repository());
  ///
  /// testWidgets('Override example', (tester) async {
  ///   await tester.pumpWidget(
  ///     ProviderScope(
  ///       overrides: [
  ///         repositoryProvider.overrideAs(
  ///           Provider((_) => FakeRepository()),
  ///         ),
  ///       ],
  ///       child: MyApp(),
  ///     ),
  ///   );
  /// });
  /// ```
  ProviderOverride overrideAs(
    // Always alive providers can only be overriden by always alive providers
    // as automatically disposed providers wouldn't work.
    AlwaysAliveProvider<Dependency, Result> provider,
  ) {
    return ProviderOverride._(provider, this);
  }
}
