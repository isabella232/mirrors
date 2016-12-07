module Mirrors
  # A specific mirror for a class, that includes all the capabilites
  # and information we can gather about classes.
  class ClassMirror < ObjectMirror
    # We are careful to not call methods directly on +@subject+ here, since
    # people really like to override weird methods on their classes. Instead we
    # borrow the methods from +Module+, +Kernel+, or +Class+ directly and bind
    # them to the subject.
    #
    # We don't need to be nearly as careful about this with +Method+ or
    # +UnboundMethod+ objects, since their +@subject+s are two core classes,
    # not an arbitrary user class.

    def initialize(obj)
      super(obj)
      @field_mirrors = {}
      @method_mirrors = {}
    end

    # What is the primary defining file for this class/module?
    # This is necessarily best-effort but it will be right in simple cases.
    #
    # @return [String, nil] the path on disk to the file, if determinable.
    def file
      Mirrors::PackageInference::ClassToFileResolver.new.resolve(self)
    end

    # @return [true, false] Is this a Class, as opposed to a Module?
    def is_class # rubocop:disable Style/PredicateName
      subject_is_a?(Class)
    end

    # @todo not yet implemented
    # @return [PackageMirror] the "package" into which this class/module has
    #   been sorted.
    def package
      # TODO(burke)
    end

    # All constants, class vars, and class instance vars.
    # @return [Array<FieldMirror>]
    def fields
      [constants, class_variables, class_instance_variables].flatten
    end

    # The known class variables.
    # @return [Array<FieldMirror>]
    def class_variables
      field_mirrors(subject_send_from_module(:class_variables))
    end

    # The known class instance variables.
    # @return [Array<FieldMirror>]
    def class_instance_variables
      field_mirrors(subject_send_from_module(:instance_variables))
    end

    # The source files this class is defined and/or extended in.
    #
    # @return [Array<String,File>]
    def source_files
      locations = subject_send_from_module(:instance_methods, false).collect do |name|
        method = subject_send_from_module(:instance_method, name)
        sl = method.source_location
        sl.first if sl
      end
      locations.compact.uniq
    end

    # @return [ClassMirror] The singleton class of this class
    def singleton_class
      Mirrors.reflect(subject_singleton_class)
    end

    # @return [true,false] Is the subject is a singleton class?
    def singleton_class?
      n = name
      # #<Class:0x1234deadbeefcafe> is an anonymous class.
      # #<Class:A> is the singleton class of A
      # #<Class:#<Class:0x1234deadbeefcafe>> is the ginelton class of an
      #   anonymous class
      n.match(/^\#<Class:.*>$/) && !n.match(/^\#<Class:0x\h+>$/)
    end

    # @return [true,false] Is this an anonymous class or module?
    def anonymous?
      name.match(/^\#<(Class|Module):0x\h+>$/)
    end

    # @return [Array<ClassMirror>] The mixins included in the ancestors of this
    #   class.
    def mixins
      mirrors(subject_send_from_module(:ancestors).reject { |m| m.is_a?(Class) })
    end

    # @return [ClassMirror] The direct superclass
    def superclass
      Mirrors.reflect(subject_superclass)
    end

    # @return [Array<ClassMirror>] The known subclasses
    def subclasses
      mirrors(ObjectSpace.each_object(Class).select { |a| a.superclass == @subject })
    end

    # @return [Array<ClassMirror>] The list of ancestors
    def ancestors
      mirrors(subject_send_from_module(:ancestors))
    end

    # The constants defined within this class. This includes nested
    # classes and modules, but also all other kinds of constants.
    #
    # @return [Array<FieldMirror>]
    def constants
      field_mirrors(subject_send_from_module(:constants))
    end

    # Searches for the named constant in the mirrored namespace. May
    # include a colon (::) separated constant path. This _may_ trigger
    # an autoload!
    #
    # @return [ClassMirror, nil] the requested constant, or nil
    def constant(str)
      path = str.to_s.split("::")
      c = path[0..-2].inject(@subject) do |klass, s|
        Mirrors.rebind(Module, klass, :const_get).call(s)
      end

      field_mirror((c || @subject), path.last)
    rescue NameError => e
      p e
      nil
    end

    # @todo does this actually return +ClassMirror+s?
    # @return [Array<ClassMirror>] The full module nesting.
    def nesting
      ary = []
      subject_send_from_module(:name).split('::').inject(Object) do |klass, str|
        ary << Mirrors.rebind(Module, klass, :const_get).call(str)
        ary.last
      end
      ary.reverse
    rescue NameError
      [@subject]
    end

    # @return [Array<ClassMirror>] The classes nested within the subject.
    def nested_classes
      nc = subject_send_from_module(:constants).map do |c|
        # do not trigger autoloads
        if subject_send_from_module(:const_defined?, c) && !subject_send_from_module(:autoload?, c)
          subject_send_from_module(:const_get, c)
        end
      end

      consts = nc.compact.select do |c|
        Mirrors.rebind(Kernel, c, :is_a?).call(Module)
      end

      mirrors(consts.sort_by { |c| Mirrors.rebind(Module, c, :name).call })
    end

    def nested_class_count
      nested_classes.count
    end

    # The instance methods of this class.
    #
    # @return [Array<MethodMirror>]
    def class_methods
      mirrors(all_instance_methods(subject_singleton_class))
    end

    # The instance methods of this class. To get to the class methods,
    # ask the #singleton_class for its methods.
    #
    # @return [Array<MethodMirror>]
    def instance_methods
      mirrors(all_instance_methods(@subject))
    end

    # The instance method of this class or any of its superclasses
    # that has the specified selector
    #
    # @param [Symbol] name of the method to look up
    # @return [MethodMirror, nil] the method or nil, if none was found
    # @raise [NameError] if the module isn't present
    def instance_method(name)
      Mirrors.reflect(subject_send_from_module(:instance_method, name))
    end

    # The singleton/static method of this class or any of its superclasses
    # that has the specified selector
    #
    # @param [Symbol] name of the method to look up
    # @return [MethodMirror, nil] the method or nil, if none was found
    # @raise [NameError] if the module isn't present
    def class_method(name)
      m = Mirrors.rebind(Module, subject_singleton_class, :instance_method).call(name)
      Mirrors.reflect(m)
    end

    # This will probably prevent confusion
    alias_method :__methods, :methods
    undef methods
    alias_method :__method, :method
    undef method

    # @return [String]
    def name
      # +name+ itself is blank for anonymous/singleton classes
      subject_send_from_module(:inspect)
    end

    def demodulized_name
      name.split('::').last
    end

    def intern_method_mirror(mirror)
      @method_mirrors[mirror.name] ||= mirror
    end

    def intern_field_mirror(mirror)
      @field_mirrors[mirror.name] ||= mirror
    end

    private

    # This one is not defined on Module since it only applies to classes
    def subject_superclass
      Mirrors.rebind(Class.singleton_class, @subject, :superclass).call
    end

    def subject_send_from_module(message, *args)
      Mirrors.rebind(Module, @subject, message).call(*args)
    end

    def all_instance_methods(mod)
      pub_prot_names = Mirrors.rebind(Module, mod, :instance_methods).call(false)
      priv_names = Mirrors.rebind(Module, mod, :private_instance_methods).call(false)

      (pub_prot_names.sort + priv_names.sort).map do |n|
        Mirrors.rebind(Module, mod, :instance_method).call(n)
      end
    end
  end
end
