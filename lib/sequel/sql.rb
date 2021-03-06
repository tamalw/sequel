module Sequel
  if RUBY_VERSION < '1.9.0'
    # If on Ruby 1.8, create a <tt>Sequel::BasicObject</tt> class that is similar to the
    # the Ruby 1.9 +BasicObject+ class.  This is used in a few places where proxy
    # objects are needed that respond to any method call.
    class BasicObject
      # The instance methods to not remove from the class when removing
      # other methods.
      KEEP_METHODS = %w"__id__ __send__ __metaclass__ instance_eval == equal? initialize"

      # Remove all but the most basic instance methods from the class.  A separate
      # method so that it can be called again if necessary if you load libraries
      # after Sequel that add instance methods to +Object+.
      def self.remove_methods!
        ((private_instance_methods + instance_methods) - KEEP_METHODS).each{|m| undef_method(m)}
      end
      remove_methods!
    end
  else
    # If on 1.9, create a <tt>Sequel::BasicObject</tt> class that is just like the
    # default +BasicObject+ class, except that missing constants are resolved in
    # +Object+.  This allows the virtual row support to work with classes
    # without prefixing them with ::, such as:
    #
    #   DB[:bonds].filter{maturity_date > Time.now}
    class BasicObject < ::BasicObject
      # Lookup missing constants in <tt>::Object</tt>
      def self.const_missing(name)
        ::Object.const_get(name)
      end

      # No-op method on ruby 1.9, which has a real +BasicObject+ class.
      def self.remove_methods!
      end
    end
  end

  class LiteralString < ::String
  end

  # The SQL module holds classes whose instances represent SQL fragments.
  # It also holds modules that are included in core ruby classes that
  # make Sequel a friendly DSL.
  module SQL

    ### Parent Classes ###

    # Classes/Modules aren't in alphabetical order due to the fact that
    # some reference constants defined in others at load time.

    # Base class for all SQL expression objects.
    class Expression
      # Expression objects are assumed to be value objects, where their
      # attribute values can't change after assignment.  In order to make
      # it easy to define equality and hash methods, subclass
      # instances assume that the only values that affect the results of
      # such methods are the values of the object's attributes.
      def self.attr_reader(*args)
        super
        comparison_attrs.concat args
      end

      # All attributes used for equality and hash methods.
      def self.comparison_attrs
        @comparison_attrs ||= self == Expression ? [] : superclass.comparison_attrs.clone
      end

      # Create a to_s instance method that takes a dataset, and calls
      # the method provided on the dataset with args as the argument (self by default).
      # Used to DRY up some code.
      def self.to_s_method(meth, args=:self) # :nodoc:
        class_eval("def to_s(ds); ds.#{meth}(#{args}) end", __FILE__, __LINE__)
      end
      private_class_method :to_s_method

      # Alias of <tt>eql?</tt>
      def ==(other)
        eql?(other)
      end

      # Returns true if the receiver is the same expression as the
      # the +other+ expression.
      def eql?(other)
        other.is_a?(self.class) && !self.class.comparison_attrs.find{|a| send(a) != other.send(a)}
      end

      # Make sure that the hash value is the same if the attributes are the same.
      def hash
        ([self.class] + self.class.comparison_attrs.map{|x| send(x)}).hash
      end

      # Show the class name and instance variables for the object, necessary
      # for correct operation on ruby 1.9.2.
      def inspect
        "#<#{self.class} #{instance_variables.map{|iv| "#{iv}=>#{instance_variable_get(iv).inspect}"}.join(', ')}>"
      end

      # Returns +self+, because <tt>SQL::Expression</tt> already acts like +LiteralString+.
      def lit
        self
      end
      
      # Alias of +to_s+
      def sql_literal(ds)
        to_s(ds)
      end
    end

    # Represents a complex SQL expression, with a given operator and one
    # or more attributes (which may also be ComplexExpressions, forming
    # a tree).  This class is the backbone of Sequel's ruby expression DSL.
    #
    # This is an abstract class that is not that useful by itself.  The
    # subclasses +BooleanExpression+, +NumericExpression+, and +StringExpression+
    # define the behavior of the DSL via operators.
    class ComplexExpression < Expression
      # A hash of the opposite for each operator symbol, used for inverting
      # objects.
      OPERTATOR_INVERSIONS = {:AND => :OR, :OR => :AND, :< => :>=, :> => :<=,
        :<= => :>, :>= => :<, :'=' => :'!=' , :'!=' => :'=', :LIKE => :'NOT LIKE',
        :'NOT LIKE' => :LIKE, :~ => :'!~', :'!~' => :~, :IN => :'NOT IN',
        :'NOT IN' => :IN, :IS => :'IS NOT', :'IS NOT' => :IS, :'~*' => :'!~*',
        :'!~*' => :'~*', :NOT => :NOOP, :NOOP => :NOT, :ILIKE => :'NOT ILIKE',
        :'NOT ILIKE'=>:ILIKE}

      # Standard mathematical operators used in +NumericMethods+
      MATHEMATICAL_OPERATORS = [:+, :-, :/, :*]

      # Bitwise mathematical operators used in +NumericMethods+
      BITWISE_OPERATORS = [:&, :|, :^, :<<, :>>]

      # Inequality operators used in +InequalityMethods+
      INEQUALITY_OPERATORS = [:<, :>, :<=, :>=]

      # Hash of ruby operator symbols to SQL operators, used in +BooleanMethods+
      BOOLEAN_OPERATOR_METHODS = {:& => :AND, :| =>:OR}

      # Operators that use IN/NOT IN for inclusion/exclusion
      IN_OPERATORS = [:IN, :'NOT IN']

      # Operators that use IS, used for special casing to override literal true/false values
      IS_OPERATORS = [:IS, :'IS NOT']

      # Operator symbols that take exactly two arguments
      TWO_ARITY_OPERATORS = [:'=', :'!=', :LIKE, :'NOT LIKE', \
        :~, :'!~', :'~*', :'!~*', :ILIKE, :'NOT ILIKE'] + \
        INEQUALITY_OPERATORS + BITWISE_OPERATORS + IS_OPERATORS + IN_OPERATORS

      # Operator symbols that take one or more arguments
      N_ARITY_OPERATORS = [:AND, :OR, :'||'] + MATHEMATICAL_OPERATORS

      # Operator symbols that take only a single argument
      ONE_ARITY_OPERATORS = [:NOT, :NOOP, :'B~']

      # An array of args for this object
      attr_reader :args

      # The operator symbol for this object
      attr_reader :op
      
      # Set the operator symbol and arguments for this object to the ones given.
      # Convert all args that are hashes or arrays of two element arrays to +BooleanExpressions+,
      # other than the second arg for an IN/NOT IN operator.
      # Raise an +Error+ if the operator doesn't allow boolean input and a boolean argument is given.
      # Raise an +Error+ if the wrong number of arguments for a given operator is used.
      def initialize(op, *args)
        orig_args = args
        args = args.map{|a| Sequel.condition_specifier?(a) ? SQL::BooleanExpression.from_value_pairs(a) : a}
        case op
        when *N_ARITY_OPERATORS
          raise(Error, "The #{op} operator requires at least 1 argument") unless args.length >= 1
          old_args = args
          args = []
          old_args.each{|a| a.is_a?(self.class) && a.op == op ? args.concat(a.args) : args.push(a)}
        when *TWO_ARITY_OPERATORS
          raise(Error, "The #{op} operator requires precisely 2 arguments") unless args.length == 2
          # With IN/NOT IN, even if the second argument is an array of two element arrays,
          # don't convert it into a boolean expression, since it's definitely being used
          # as a value list.
          args[1] = orig_args[1] if IN_OPERATORS.include?(op)
        when *ONE_ARITY_OPERATORS
          raise(Error, "The #{op} operator requires a single argument") unless args.length == 1
        else
          raise(Error, "Invalid operator #{op}")
        end
        @op = op
        @args = args
      end
      
      to_s_method :complex_expression_sql, '@op, @args'
    end

    # The base class for expressions that can be used in multiple places in
    # an SQL query.  
    class GenericExpression < Expression
    end
    
    ### Modules ###

    # Includes an +as+ method that creates an SQL alias.
    module AliasMethods
      # Create an SQL alias (+AliasedExpression+) of the receiving column or expression to the given alias.
      #
      #   :column.as(:alias) # "column" AS "alias"
      def as(aliaz)
        AliasedExpression.new(self, aliaz)
      end
    end

    # This defines the bitwise methods: &, |, ^, ~, <<, and >>.  Because these
    # methods overlap with the standard +BooleanMethods methods+, and they only
    # make sense for integers, they are only included in +NumericExpression+.
    #
    #   :a.sql_number & :b # "a" & "b"
    #   :a.sql_number | :b # "a" | "b"
    #   :a.sql_number ^ :b # "a" ^ "b"
    #   :a.sql_number << :b # "a" << "b"
    #   :a.sql_number >> :b # "a" >> "b"
    #   ~:a.sql_number # ~"a"
    module BitwiseMethods
      ComplexExpression::BITWISE_OPERATORS.each do |o|
        define_method(o) do |ce|
          case ce
          when BooleanExpression, StringExpression
            raise(Sequel::Error, "cannot apply #{o} to a non-numeric expression")
          else  
            NumericExpression.new(o, self, ce)
          end
        end
      end

      # Do the bitwise compliment of the self
      #
      #   ~:a.sql_number # ~"a"
      def ~
        NumericExpression.new(:'B~', self)
      end
    end

    # This module includes the boolean/logical AND (&), OR (|) and NOT (~) operators
    # that are defined on objects that can be used in a boolean context in SQL
    # (+Symbol+, +LiteralString+, and <tt>SQL::GenericExpression</tt>).
    #
    #   :a & :b # "a" AND "b"
    #   :a | :b # "a" OR "b"
    #   ~:a # NOT "a"
    module BooleanMethods
      ComplexExpression::BOOLEAN_OPERATOR_METHODS.each do |m, o|
        define_method(m) do |ce|
          case ce
          when NumericExpression, StringExpression
            raise(Sequel::Error, "cannot apply #{o} to a non-boolean expression")
          else  
            BooleanExpression.new(o, self, ce)
          end
        end
      end
      
      # Create a new BooleanExpression with NOT, representing the inversion of whatever self represents.
      #
      #   ~:a # NOT :a
      def ~
        BooleanExpression.invert(self)
      end
    end

    # Holds methods that are used to cast objects to different SQL types.
    module CastMethods 
      # Cast the reciever to the given SQL type.  You can specify a ruby class as a type,
      # and it is handled similarly to using a database independent type in the schema methods.
      #
      #   :a.cast(:integer) # CAST(a AS integer)
      #   :a.cast(String) # CAST(a AS varchar(255))
      def cast(sql_type)
        Cast.new(self, sql_type)
      end

      # Cast the reciever to the given SQL type (or the database's default Integer type if none given),
      # and return the result as a +NumericExpression+, so you can use the bitwise operators
      # on the result. 
      #
      #   :a.cast_numeric # CAST(a AS integer)
      #   :a.cast_numeric(Float) # CAST(a AS double precision)
      def cast_numeric(sql_type = nil)
        cast(sql_type || Integer).sql_number
      end

      # Cast the reciever to the given SQL type (or the database's default String type if none given),
      # and return the result as a +StringExpression+, so you can use +
      # directly on the result for SQL string concatenation.
      #
      #   :a.cast_string # CAST(a AS varchar(255))
      #   :a.cast_string(:text) # CAST(a AS text)
      def cast_string(sql_type = nil)
        cast(sql_type || String).sql_string
      end
    end
    
    # Adds methods that allow you to treat an object as an instance of a specific
    # +ComplexExpression+ subclass.  This is useful if another library
    # overrides the methods defined by Sequel.
    #
    # For example, if <tt>Symbol#/</tt> is overridden to produce a string (for
    # example, to make file system path creation easier), the
    # following code will not do what you want:
    #
    #   :price/10 > 100
    #
    # In that case, you need to do the following:
    #
    #   :price.sql_number/10 > 100
    module ComplexExpressionMethods
      # Extract a datetime_part (e.g. year, month) from self:
      #
      #   :date.extract(:year) # extract(year FROM "date")
      #
      # Also has the benefit of returning the result as a
      # NumericExpression instead of a generic ComplexExpression.
      #
      # The extract function is in the SQL standard, but it doesn't
      # doesn't use the standard function calling convention, and it
      # doesn't work on all databases.
      def extract(datetime_part)
        Function.new(:extract, PlaceholderLiteralString.new("#{datetime_part} FROM ?", [self])).sql_number
      end

      # Return a BooleanExpression representation of +self+.
      def sql_boolean
        BooleanExpression.new(:NOOP, self)
      end

      # Return a NumericExpression representation of +self+.
      # 
      #   ~:a # NOT "a"
      #   ~:a.sql_number # ~"a"
      def sql_number
        NumericExpression.new(:NOOP, self)
      end

      # Return a StringExpression representation of +self+.
      #
      #   :a + :b # "a" + "b"
      #   :a.sql_string + :b # "a" || "b"
      def sql_string
        StringExpression.new(:NOOP, self)
      end
    end

    # Includes an +identifier+ method that returns <tt>Identifier</tt>s.
    module IdentifierMethods
      # Return self wrapped as an <tt>SQL::Identifier</tt>.
      #
      #   :a__b # "a"."b"
      #   :a__b.identifier # "a__b"
      def identifier
        Identifier.new(self)
      end
    end

    # This module includes the inequality methods (>, <, >=, <=) that are defined on objects that can be 
    # used in a numeric or string context in SQL (+Symbol+ (except on ruby 1.9), +LiteralString+, 
    # <tt>SQL::GenericExpression</tt>).
    #
    #   'a'.lit > :b # a > "b"
    #   'a'.lit < :b # a > "b"
    #   'a'.lit >= :b # a >= "b"
    #   'a'.lit <= :b # a <= "b"
    module InequalityMethods
      ComplexExpression::INEQUALITY_OPERATORS.each do |o|
        define_method(o) do |ce|
          case ce
          when BooleanExpression, TrueClass, FalseClass, NilClass, Hash, ::Array
            raise(Error, "cannot apply #{o} to a boolean expression")
          else  
            BooleanExpression.new(o, self, ce)
          end
        end
      end
    end

    # This module augments the default initalize method for the 
    # +ComplexExpression+ subclass it is included in, so that
    # attempting to use boolean input when initializing a +NumericExpression+
    # or +StringExpression+ results in an error.  It is not expected to be
    # used directly.
    module NoBooleanInputMethods
      # Raise an +Error+ if one of the args would be boolean in an SQL
      # context, otherwise call super.
      def initialize(op, *args)
        args.each do |a|
          case a
          when BooleanExpression, TrueClass, FalseClass, NilClass, Hash, ::Array
            raise(Error, "cannot apply #{op} to a boolean expression")
          end
        end
        super
      end
    end

    # This module includes the standard mathematical methods (+, -, *, and /)
    # that are defined on objects that can be used in a numeric context in SQL
    # (+Symbol+, +LiteralString+, and +SQL::GenericExpression+).
    #
    #   :a + :b # "a" + "b"
    #   :a - :b # "a" - "b"
    #   :a * :b # "a" * "b"
    #   :a / :b # "a" / "b"
    module NumericMethods
      ComplexExpression::MATHEMATICAL_OPERATORS.each do |o|
        define_method(o) do |ce|
          case ce
          when BooleanExpression, StringExpression
            raise(Sequel::Error, "cannot apply #{o} to a non-numeric expression")
          else  
            NumericExpression.new(o, self, ce)
          end
        end
      end
    end

    # Methods that create +OrderedExpressions+, used for sorting by columns
    # or more complex expressions.
    module OrderMethods
      # Mark the receiving SQL column as sorting in an ascending fashion (generally a no-op).
      # Options:
      #
      # :nulls :: Set to :first to use NULLS FIRST (so NULL values are ordered
      #           before other values), or :last to use NULLS LAST (so NULL values
      #           are ordered after other values).
      def asc(opts={})
        OrderedExpression.new(self, false, opts)
      end
      
      # Mark the receiving SQL column as sorting in a descending fashion.
      # Options:
      #
      # :nulls :: Set to :first to use NULLS FIRST (so NULL values are ordered
      #           before other values), or :last to use NULLS LAST (so NULL values
      #           are ordered after other values).
      def desc(opts={})
        OrderedExpression.new(self, true, opts)
      end
    end

    # Includes a +qualify+ method that created <tt>QualifiedIdentifier</tt>s, used for qualifying column
    # names with a table or table names with a schema.
    module QualifyingMethods
      # Qualify the receiver with the given +qualifier+ (table for column/schema for table).
      #
      #   :column.qualify(:table) # "table"."column"
      #   :table.qualify(:schema) # "schema"."table"
      #   :column.qualify(:table).qualify(:schema) # "schema"."table"."column"
      def qualify(qualifier)
        QualifiedIdentifier.new(qualifier, self)
      end
    end

    # This module includes the +like+ and +ilike+ methods used for pattern matching that are defined on objects that can be 
    # used in a string context in SQL (+Symbol+, +LiteralString+, <tt>SQL::GenericExpression</tt>).
    module StringMethods
      # Create a +BooleanExpression+ case insensitive pattern match of the receiver
      # with the given patterns.  See <tt>StringExpression.like</tt>.
      #
      #   :a.ilike('A%') # "a" ILIKE 'A%'
      def ilike(*ces)
        StringExpression.like(self, *(ces << {:case_insensitive=>true}))
      end

      # Create a +BooleanExpression+ case sensitive (if the database supports it) pattern match of the receiver with
      # the given patterns.  See <tt>StringExpression.like</tt>.
      #
      #   :a.like('A%') # "a" LIKE 'A%'
      def like(*ces)
        StringExpression.like(self, *ces)
      end
    end

    # This module includes the <tt>+</tt> method.  It is included in +StringExpression+ and can be included elsewhere
    # to allow the use of the + operator to represent concatenation of SQL Strings:
    module StringConcatenationMethods
      # Return a +StringExpression+ representing the concatenation of the receiver
      # with the given argument.
      #
      #   :x.sql_string + :y => # "x" || "y"
      def +(ce)
        StringExpression.new(:'||', self, ce)
      end
    end

    # This module includes the +sql_subscript+ method, representing SQL array accesses.
    module SubscriptMethods
      # Return a <tt>Subscript</tt> with the given arguments, representing an
      # SQL array access.
      #
      #   :array.sql_subscript(1) # array[1]
      #   :array.sql_subscript(1, 2) # array[1, 2]
      #   :array.sql_subscript([1, 2]) # array[1, 2]
      def sql_subscript(*sub)
        Subscript.new(self, sub.flatten)
      end
    end

    ### Classes ###

    # Represents an aliasing of an expression to a given alias.
    class AliasedExpression < Expression
      # The expression to alias
      attr_reader :expression

      # The alias to use for the expression, not +alias+ since that is
      # a keyword in ruby.
      attr_reader :aliaz

      # Create an object with the given expression and alias.
      def initialize(expression, aliaz)
        @expression, @aliaz = expression, aliaz
      end

      to_s_method :aliased_expression_sql
    end

    # +Blob+ is used to represent binary data in the Ruby environment that is
    # stored as a blob type in the database. Sequel represents binary data as a Blob object because 
    # most database engines require binary data to be escaped differently than regular strings.
    class Blob < ::String
      # Returns +self+, used so that Blobs don't get wrapped in multiple
      # levels.
      def to_sequel_blob
        self
      end
    end

    # Subclass of +ComplexExpression+ where the expression results
    # in a boolean value in SQL.
    class BooleanExpression < ComplexExpression
      include BooleanMethods
      
      # Take pairs of values (e.g. a hash or array of two element arrays)
      # and converts it to a +BooleanExpression+.  The operator and args
      # used depends on the case of the right (2nd) argument:
      #
      # * 0..10 - left >= 0 AND left <= 10
      # * [1,2] - left IN (1,2)
      # * nil - left IS NULL
      # * true - left IS TRUE 
      # * false - left IS FALSE 
      # * /as/ - left ~ 'as'
      # * :blah - left = blah
      # * 'blah' - left = 'blah'
      #
      # If multiple arguments are given, they are joined with the op given (AND
      # by default, OR possible).  If negate is set to true,
      # all subexpressions are inverted before used.  Therefore, the following
      # expressions are equivalent:
      #
      #   ~from_value_pairs(hash)
      #   from_value_pairs(hash, :OR, true)
      def self.from_value_pairs(pairs, op=:AND, negate=false)
        pairs = pairs.collect do |l,r|
          ce = case r
          when Range
            new(:AND, new(:>=, l, r.begin), new(r.exclude_end? ? :< : :<=, l, r.end))
          when ::Array, ::Sequel::Dataset
            new(:IN, l, r)
          when NegativeBooleanConstant
            new(:"IS NOT", l, r.constant)
          when BooleanConstant
            new(:IS, l, r.constant)
          when NilClass, TrueClass, FalseClass
            new(:IS, l, r)
          when Regexp
            StringExpression.like(l, r)
          else
            new(:'=', l, r)
          end
          negate ? invert(ce) : ce
        end
        pairs.length == 1 ? pairs.at(0) : new(op, *pairs)
      end
      
      # Invert the expression, if possible.  If the expression cannot
      # be inverted, raise an error.  An inverted expression should match everything that the
      # uninverted expression did not match, and vice-versa, except for possible issues with
      # SQL NULL (i.e. 1 == NULL is NULL and 1 != NULL is also NULL).
      #
      #   BooleanExpression.invert(:a) # NOT "a"
      def self.invert(ce)
        case ce
        when BooleanExpression
          case op = ce.op
          when :AND, :OR
            BooleanExpression.new(OPERTATOR_INVERSIONS[op], *ce.args.collect{|a| BooleanExpression.invert(a)})
          else
            BooleanExpression.new(OPERTATOR_INVERSIONS[op], *ce.args.dup)
          end
        when StringExpression, NumericExpression
          raise(Sequel::Error, "cannot invert #{ce.inspect}")
        else
          BooleanExpression.new(:NOT, ce)
        end
      end
    end

    # Represents an SQL CASE expression, used for conditional branching in SQL.
    class CaseExpression < GenericExpression
      # An array of all two pairs with the first element specifying the
      # condition and the second element specifying the result if the
      # condition matches.
      attr_reader :conditions

      # The default value if no conditions match. 
      attr_reader :default

      # The expression to test the conditions against
      attr_reader :expression

      # Create an object with the given conditions and
      # default value.  An expression can be provided to
      # test each condition against, instead of having
      # all conditions represent their own boolean expression.
      def initialize(conditions, default, expression=(no_expression=true; nil))
        raise(Sequel::Error, 'CaseExpression conditions must be a hash or array of all two pairs') unless Sequel.condition_specifier?(conditions)
        @conditions, @default, @expression, @no_expression = conditions.to_a, default, expression, no_expression
      end

      # Whether to use an expression for this CASE expression.
      def expression?
        !@no_expression
      end

      to_s_method :case_expression_sql
    end

    # Represents a cast of an SQL expression to a specific type.
    class Cast < GenericExpression
      # The expression to cast
      attr_reader :expr

      # The type to which to cast the expression
      attr_reader :type
      
      # Set the attributes to the given arguments
      def initialize(expr, type)
        @expr = expr
        @type = type
      end

      to_s_method :cast_sql, '@expr, @type'
    end

    # Represents all columns in a given table, table.* in SQL
    class ColumnAll < Expression
      # The table containing the columns being selected
      attr_reader :table

      # Create an object with the given table
      def initialize(table)
        @table = table
      end

      to_s_method :column_all_sql
    end
    
    class ComplexExpression
      include AliasMethods
      include CastMethods
      include OrderMethods
      include SubscriptMethods
    end

    # Represents constants or psuedo-constants (e.g. +CURRENT_DATE+) in SQL.
    class Constant < GenericExpression
      # The underlying constant related to this object.
      attr_reader :constant

      # Create an constant with the given value
      def initialize(constant)
        @constant = constant
      end
      
      to_s_method :constant_sql, '@constant'
    end

    # Represents boolean constants such as +NULL+, +NOTNULL+, +TRUE+, and +FALSE+.
    class BooleanConstant < Constant
      to_s_method :boolean_constant_sql, '@constant'
    end
    
    # Represents inverse boolean constants (currently only +NOTNULL+). A
    # special class to allow for special behavior.
    class NegativeBooleanConstant < BooleanConstant
      to_s_method :negative_boolean_constant_sql, '@constant'
    end
    
    # Holds default generic constants that can be referenced.  These
    # are included in the Sequel top level module and are also available
    # in this module which can be required at the top level to get
    # direct access to the constants.
    module Constants
      CURRENT_DATE = Constant.new(:CURRENT_DATE)
      CURRENT_TIME = Constant.new(:CURRENT_TIME)
      CURRENT_TIMESTAMP = Constant.new(:CURRENT_TIMESTAMP)
      SQLTRUE = TRUE = BooleanConstant.new(true)
      SQLFALSE = FALSE = BooleanConstant.new(false)
      NULL = BooleanConstant.new(nil)
      NOTNULL = NegativeBooleanConstant.new(nil)
    end

    # Represents an SQL function call.
    class Function < GenericExpression
      # The array of arguments to pass to the function (may be blank)
      attr_reader :args

      # The SQL function to call
      attr_reader :f
      
      # Set the functions and args to the given arguments
      def initialize(f, *args)
        @f, @args = f, args
      end

      to_s_method :function_sql
    end
    
    class GenericExpression
      include AliasMethods
      include BooleanMethods
      include CastMethods
      include ComplexExpressionMethods
      include InequalityMethods
      include NumericMethods
      include OrderMethods
      include StringMethods
      include SubscriptMethods
    end

    # Represents an identifier (column or table). Can be used
    # to specify a +Symbol+ with multiple underscores should not be
    # split, or for creating an identifier without using a symbol.
    class Identifier < GenericExpression
      include QualifyingMethods

      # The table or column to reference
      attr_reader :value

      # Set the value to the given argument
      def initialize(value)
        @value = value
      end
      
      to_s_method :quote_identifier, '@value'
    end
    
    # Represents an SQL JOIN clause, used for joining tables.
    class JoinClause < Expression
      # The type of join to do
      attr_reader :join_type

      # The actual table to join
      attr_reader :table

      # The table alias to use for the join, if any
      attr_reader :table_alias

      # Create an object with the given join_type, table, and table alias
      def initialize(join_type, table, table_alias = nil)
        @join_type, @table, @table_alias = join_type, table, table_alias
      end

      to_s_method :join_clause_sql
    end

    # Represents an SQL JOIN clause with ON conditions.
    class JoinOnClause < JoinClause
      # The conditions for the join
      attr_reader :on

      # Create an object with the ON conditions and call super with the
      # remaining args.
      def initialize(on, *args)
        @on = on
        super(*args)
      end

      to_s_method :join_on_clause_sql
    end

    # Represents an SQL JOIN clause with USING conditions.
    class JoinUsingClause < JoinClause
      # The columns that appear in both tables that should be equal 
      # for the conditions to match.
      attr_reader :using

      # Create an object with the given USING conditions and call super
      # with the remaining args.
      def initialize(using, *args)
        @using = using
        super(*args)
      end

      to_s_method :join_using_clause_sql
    end

    # Represents a literal string with placeholders and arguments.
    # This is necessary to ensure delayed literalization of the arguments
    # required for the prepared statement support and for database-specific
    # literalization.
    class PlaceholderLiteralString < GenericExpression
      # The arguments that will be subsituted into the placeholders.
      # Either an array of unnamed placeholders (which will be substituted in
      # order for ? characters), or a hash of named placeholders (which will be
      # substituted for :key phrases).
      attr_reader :args

      # The literal string containing placeholders
      attr_reader :str

      # Whether to surround the expression with parantheses
      attr_reader :parens

      # Create an object with the given string, placeholder arguments, and parens flag.
      def initialize(str, args, parens=false)
        @str = str
        @args = args.is_a?(Array) && args.length == 1 && (v = args.at(0)).is_a?(Hash) ? v : args
        @parens = parens
      end

      to_s_method :placeholder_literal_string_sql
    end

    # Subclass of +ComplexExpression+ where the expression results
    # in a numeric value in SQL.
    class NumericExpression < ComplexExpression
      include BitwiseMethods 
      include NumericMethods
      include InequalityMethods
      include NoBooleanInputMethods
    end

    # Represents a column/expression to order the result set by.
    class OrderedExpression < Expression
      INVERT_NULLS = {:first=>:last, :last=>:first}.freeze

      # The expression to order the result set by.
      attr_reader :expression

      # Whether the expression should order the result set in a descending manner
      attr_reader :descending

      # Whether to sort NULLS FIRST/LAST
      attr_reader :nulls

      # Set the expression and descending attributes to the given values.
      # Options:
      #
      # :nulls :: Can be :first/:last for NULLS FIRST/LAST.
      def initialize(expression, descending = true, opts={})
        @expression, @descending, @nulls = expression, descending, opts[:nulls]
      end

      # Return a copy that is ordered ASC
      def asc
        OrderedExpression.new(@expression, false, :nulls=>@nulls)
      end

      # Return a copy that is ordered DESC
      def desc
        OrderedExpression.new(@expression, true, :nulls=>@nulls)
      end

      # Return an inverted expression, changing ASC to DESC and NULLS FIRST to NULLS LAST.
      def invert
        OrderedExpression.new(@expression, !@descending, :nulls=>INVERT_NULLS.fetch(@nulls, @nulls))
      end

      to_s_method :ordered_expression_sql
    end

    # Represents a qualified identifier (column with table or table with schema).
    class QualifiedIdentifier < GenericExpression
      include QualifyingMethods

      # The column/table referenced
      attr_reader :column

      # The table/schema qualifying the reference
      attr_reader :table

      # Set the table and column to the given arguments
      def initialize(table, column)
        @table, @column = table, column
      end
      
      to_s_method :qualified_identifier_sql
    end
    
    # Subclass of +ComplexExpression+ where the expression results
    # in a text/string/varchar value in SQL.
    class StringExpression < ComplexExpression
      include StringMethods
      include StringConcatenationMethods
      include InequalityMethods
      include NoBooleanInputMethods

      # Map of [regexp, case_insenstive] to +ComplexExpression+ operator symbol
      LIKE_MAP = {[true, true]=>:'~*', [true, false]=>:~, [false, true]=>:ILIKE, [false, false]=>:LIKE}
      
      # Creates a SQL pattern match exprssion. left (l) is the SQL string we
      # are matching against, and ces are the patterns we are matching.
      # The match succeeds if any of the patterns match (SQL OR).
      #
      # If a regular expression is used as a pattern, an SQL regular expression will be
      # used, which is currently only supported on MySQL and PostgreSQL.  Be aware
      # that MySQL and PostgreSQL regular expression syntax is similar to ruby
      # regular expression syntax, but it not exactly the same, especially for
      # advanced regular expression features.  Sequel just uses the source of the
      # ruby regular expression verbatim as the SQL regular expression string.
      #
      # If any other object is used as a regular expression, the SQL LIKE operator will
      # be used, and should be supported by most databases.  
      # 
      # The pattern match will be case insensitive if the last argument is a hash
      # with a key of :case_insensitive that is not false or nil. Also,
      # if a case insensitive regular expression is used (//i), that particular
      # pattern which will always be case insensitive.
      #
      #   StringExpression.like(:a, 'a%') # "a" LIKE 'a%'
      #   StringExpression.like(:a, 'a%', :case_insensitive=>true) # "a" ILIKE 'a%'
      #   StringExpression.like(:a, 'a%', /^a/i) # "a" LIKE 'a%' OR "a" ~* '^a' 
      def self.like(l, *ces)
        l, lre, lci = like_element(l)
        lci = (ces.last.is_a?(Hash) ? ces.pop : {})[:case_insensitive] ? true : lci
        ces.collect! do |ce|
          r, rre, rci = like_element(ce)
          BooleanExpression.new(LIKE_MAP[[lre||rre, lci||rci]], l, r)
        end
        ces.length == 1 ? ces.at(0) : BooleanExpression.new(:OR, *ces)
      end
      
      # Returns a three element array, made up of:
      # * The object to use
      # * Whether it is a regular expression
      # * Whether it is case insensitive
      def self.like_element(re) # :nodoc:
        if re.is_a?(Regexp)
          [re.source, true, re.casefold?]
        else
          [re, false, false]
        end
      end
      private_class_method :like_element
    end

    # Represents an SQL array access, with multiple possible arguments.
    class Subscript < GenericExpression
      # The SQL array column
      attr_reader :f

      # The array of subscripts to use (should be an array of numbers)
      attr_reader :sub

      # Set the array column and subscripts to the given arguments
      def initialize(f, sub)
        @f, @sub = f, sub
      end

      # Create a new +Subscript+ appending the given subscript(s)
      # the the current array of subscripts.
      def |(sub)
        Subscript.new(@f, @sub + Array(sub))
      end
      
      to_s_method :subscript_sql
    end

    # Represents an SQL value list (IN/NOT IN predicate value).  Added so it is possible to deal with a
    # ruby array of two element arrays as an SQL value list instead of an ordered
    # hash-like conditions specifier.
    class ValueList < ::Array
    end

    # Deprecated name for +ValueList+, used for backwards compatibility
    SQLArray = ValueList

    # The purpose of the +VirtualRow+ class is to allow the easy creation of SQL identifiers and functions
    # without relying on methods defined on +Symbol+.  This is useful if another library defines
    # the methods defined by Sequel, if you are running on ruby 1.9, or if you are not using the
    # core extensions.
    #
    # An instance of this class is yielded to the block supplied to <tt>Dataset#filter</tt>, <tt>Dataset#order</tt>, and <tt>Dataset#select</tt>
    # (and the other methods that accept a block and pass it to one of those methods).
    # If the block doesn't take an argument, the block is instance_evaled in the context of
    # a new instance of this class.
    #
    # +VirtualRow+ uses +method_missing+ to return either an +Identifier+, +QualifiedIdentifier+, +Function+, or +WindowFunction+, 
    # depending on how it is called.
    #
    # If a block is _not_ given, creates one of the following objects:
    #
    # +Function+ :: Returned if any arguments are supplied, using the method name
    #               as the function name, and the arguments as the function arguments.
    # +QualifiedIdentifier+ :: Returned if the method name contains __, with the
    #                          table being the part before __, and the column being the part after.
    # +Identifier+ :: Returned otherwise, using the method name.
    #
    # If a block is given, it returns either a +Function+ or +WindowFunction+, depending on the first
    # argument to the method.  Note that the block is currently not called by the code, though
    # this may change in a future version.  If the first argument is:
    #
    # no arguments given :: creates a +Function+ with no arguments.
    # :* :: creates a +Function+ with a literal wildcard argument (*), mostly useful for COUNT.
    # :distinct :: creates a +Function+ that prepends DISTINCT to the rest of the arguments, mostly
    #              useful for aggregate functions.
    # :over :: creates a +WindowFunction+.  If a second argument is provided, it should be a hash
    #          of options which are passed to Window (with possible keys :window, :partition, :order, and :frame).  The
    #          arguments to the function itself should be specified as <tt>:*=>true</tt> for a wildcard, or via
    #          the <tt>:args</tt> option.
    #
    # Examples:
    #
    #   ds = DB[:t]
    #   # Argument yielded to block
    #   ds.filter{|r| r.name < 2} # SELECT * FROM t WHERE (name < 2)
    #   # Block without argument (instance_eval)
    #   ds.filter{name < 2} # SELECT * FROM t WHERE (name < 2)
    #   # Qualified identifiers
    #   ds.filter{table__column + 1 < 2} # SELECT * FROM t WHERE ((table.column + 1) < 2)
    #   # Functions
    #   ds.filter{is_active(1, 'arg2')} # SELECT * FROM t WHERE is_active(1, 'arg2')
    #   ds.select{version{}} # SELECT version() FROM t
    #   ds.select{count(:*){}} # SELECT count(*) FROM t
    #   ds.select{count(:distinct, col1){}} # SELECT count(DISTINCT col1) FROM t
    #   # Window Functions
    #   ds.select{rank(:over){}} # SELECT rank() OVER () FROM t
    #   ds.select{count(:over, :*=>true){}} # SELECT count(*) OVER () FROM t
    #   ds.select{sum(:over, :args=>col1, :partition=>col2, :order=>col3){}} # SELECT sum(col1) OVER (PARTITION BY col2 ORDER BY col3) FROM t
    #
    # For a more detailed explanation, see the {Virtual Rows guide}[link:files/doc/virtual_rows_rdoc.html].
    class VirtualRow < BasicObject
      WILDCARD = LiteralString.new('*').freeze
      QUESTION_MARK = LiteralString.new('?').freeze
      COMMA_SEPARATOR = LiteralString.new(', ').freeze
      DOUBLE_UNDERSCORE = '__'.freeze

      # Return an +Identifier+, +QualifiedIdentifier+, +Function+, or +WindowFunction+, depending
      # on arguments and whether a block is provided.  Does not currently call the block.
      # See the class level documentation.
      def method_missing(m, *args, &block)
        if block
          if args.empty?
            Function.new(m)
          else
            case arg = args.shift
            when :*
              Function.new(m, WILDCARD)
            when :distinct
              Function.new(m, PlaceholderLiteralString.new("DISTINCT #{args.map{QUESTION_MARK}.join(COMMA_SEPARATOR)}", args))
            when :over
              opts = args.shift || {}
              fun_args = ::Kernel.Array(opts[:*] ? WILDCARD : opts[:args])
              WindowFunction.new(Function.new(m, *fun_args), Window.new(opts))
            else
              raise Error, 'unsupported VirtualRow method argument used with block'
            end
          end
        elsif args.empty?
          table, column = m.to_s.split(DOUBLE_UNDERSCORE, 2)
          column ? QualifiedIdentifier.new(table, column) : Identifier.new(m)
        else
          Function.new(m, *args)
        end
      end
    end

    # A +Window+ is part of a window function specifying the window over which the function operates.
    # It is separated from the +WindowFunction+ class because it also can be used separately on
    # some databases.
    class Window < Expression
      # The options for this window.  Options currently supported:
      # :frame :: if specified, should be :all, :rows, or a String that is used literally. :all always operates over all rows in the
      #           partition, while :rows excludes the current row's later peers.  The default is to include
      #           all previous rows in the partition up to the current row's last peer.
      # :order :: order on the column(s) given
      # :partition :: partition/group on the column(s) given
      # :window :: base results on a previously specified named window
      attr_reader :opts

      # Set the options to the options given
      def initialize(opts={})
        @opts = opts
      end

      to_s_method :window_sql, '@opts'
    end

    # A +WindowFunction+ is a grouping of a +Function+ with a +Window+ over which it operates.
    class WindowFunction < GenericExpression
      # The function to use, should be an <tt>SQL::Function</tt>.
      attr_reader :function

      # The window to use, should be an <tt>SQL::Window</tt>.
      attr_reader :window

      # Set the function and window.
      def initialize(function, window)
        @function, @window = function, window
      end

      to_s_method :window_function_sql, '@function, @window'
    end
  end

  # +LiteralString+ is used to represent literal SQL expressions. A 
  # +LiteralString+ is copied verbatim into an SQL statement. Instances of
  # +LiteralString+ can be created by calling <tt>String#lit</tt>.
  class LiteralString
    include SQL::OrderMethods
    include SQL::ComplexExpressionMethods
    include SQL::BooleanMethods
    include SQL::NumericMethods
    include SQL::StringMethods
    include SQL::InequalityMethods
  end
  
  include SQL::Constants
end
