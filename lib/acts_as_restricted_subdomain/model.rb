module RestrictedSubdomain
  SAFE_UUID = /\A[a-f0-9-]+\Z/

  module Model
    ##
    # This method will mark a class as the subdomain model. It expects to
    # contain the subdomain in a column. You can override the default (:code)
    # by passing a :by parameter. That column will be validated for presence
    # and uniqueness, so be sure to add an index on that column.
    #
    # This will add a cattr_accessor of current which will always contain
    # the current subdomain requested from the controller.
    #
    # A method for iterating over each subdomain model is also provided,
    # called each_subdomain. Pass a block and do whatever you need to do
    # restricted to a particular scope of that subdomain. Useful for console
    # and automated tasks where each subdomain has particular features that
    # may differ from each other.
    #
    # Example:
    #   class Agency < ActiveRecord::Base
    #     use_for_restricted_subdomains :by => :code
    #   end
    #
    def use_for_restricted_subdomains(opts = {})
      cattr_accessor :aars_primary_key

      options = {
        :by => :code,
        :primary_key => :id
      }.merge(opts)
      self.aars_primary_key = options[:primary_key]
      
      validates_presence_of options[:by]
      validates_uniqueness_of options[:by]
      
      self.class_eval <<-RUBY
        def self.aars_primary_key_type
          @aars_primary_key_type ||= columns_hash[self.aars_primary_key.to_s].type
        end

        def self.current
          RequestStore.store[:current_subdomain]
        end
        
        def self.current=(other)
          obj = if other.is_a?(String) or other.is_a?(Symbol)
            where(#{options[:by]}: other).first
          else
            other
          end
            RequestStore.store[:current_subdomain] = obj
        end
        
        def self.each_subdomain(&blk)
          old_current = self.current
          all.each do |subdomain|
            self.current = subdomain
            yield blk
          end
          self.current = old_current
        end
        
        def self.with_subdomain(subdomain, &blk)
          old_current = self.current
          self.current = subdomain
          result = blk.call
          self.current = old_current
          result
        end
        
        def self.without_subdomain(&blk)
          old_current = self.current
          self.current = nil
          result = blk.call
          self.current = old_current
          result
        end
      RUBY
    end
    
    ##
    # This method marks a model as restricted to a subdomain. This means that
    # it will have an association to whatever class models your subdomain,
    # see use_for_restricted_subdomains. It overrides the default find method
    # to always include a subdomain column parameter. You need to pass the
    # subdomain class symbol and column (defaults klass to :agency).
    #
    # Adds validation for the column and a belongs_to association.
    #
    # This does not add any has_many associations in your subdomain class.
    # That is an exercise left to the user, sorry. Also beware of
    # validates_uniqueness_of. It should be scoped to the foreign key.
    #
    # If you pass an assocation symbol through the :delegate option, the subdomain
    # association will be delegated through that assocation instead of being linked
    # directly. (It is assumed that the delegate is restricted to the subdomain.)
    # The result is that model lookups will always be inner-joined to the delegate,
    # ensuring that the model is indirectly restricted.
    #
    # Example:
    #
    #   class Widget < ActiveRecord::Base
    #     acts_as_restricted_subdomain :through => :subdomain
    #   end
    #
    #   class Subdomain < ActiveRecord::Base
    #     use_for_restricted_subdomains :by => :name
    #   end
    #
    # Delegate Example: A User is "global" and is linked to one or more subdomains through
    # UserCredential. Even though the User is technically global, it will only be visible to the
    # associated subdomains.
    #
    # class User < ActiveRecord::Base
    #   acts_as_restricted_subdomain :through => :subdomain, :delegate => :user_credentials
    #   has_many :user_credentials
    # end
    #
    # class UserCredential < ActiveRecord::Base
    #   acts_as_restricted_subdomain :through => :subdomain
    # end
    #
    # Special thanks to the Caboosers who created acts_as_paranoid. This is
    # pretty much the same thing, only without the delete_all bits.
    #
    def acts_as_restricted_subdomain(opts = {})
      options = { :through => :agency }.merge(opts)
      unless restricted_to_subdomain?
        cattr_accessor :subdomain_symbol, :subdomain_klass
        self.subdomain_symbol = options[:through]
        self.subdomain_klass = options[:through].to_s.camelize.constantize
        
        # This *isn't* the restricted model, but it should always join against a delegate association
        if options[:delegate]
          cattr_accessor :subdomain_symbol_delegate, :subdomain_klass_delegate
          self.subdomain_symbol_delegate = options[:delegate].to_s
          self.subdomain_klass_delegate = options[:delegate].to_s.singularize.camelize.constantize
          
          default_scope do
            if self.subdomain_klass.current
              # Using straight sql so we can JOIN against two columns. Otherwise one must go into "WHERE", and Arel would mistakenly apply it to UPDATEs and DELETEs.
              delegate_foreign_key = reflections.with_indifferent_access[self.subdomain_symbol_delegate.to_s].foreign_key
              delegate_foreign_type = reflections.with_indifferent_access[self.subdomain_symbol_delegate.to_s].type

              subdomain_id = safe_sql_current_subdomain_primary_key
              join_args = {:delegate_table => self.subdomain_klass_delegate.table_name, :delegate_key => delegate_foreign_key, :delegate_type => delegate_foreign_type, :table_name => self.table_name, :subdomain_key => "#{self.subdomain_symbol}_id", :subdomain_id => subdomain_id}
              # Using "joins" makes records readonly, which we don't want
              joins("INNER JOIN %{delegate_table} ON %{delegate_table}.%{delegate_key} = %{table_name}.#{self.subdomain_klass.aars_primary_key} AND %{delegate_table}.%{delegate_type} = '#{self.table_name.singularize.capitalize}' AND %{delegate_table}.%{subdomain_key} = %{subdomain_id}" % join_args).readonly(false)
            else
              where('1 = 1')
            end
          end
        
        # This *is* the restricted model and should always include the id in queries
        else
          belongs_to options[:through], primary_key: self.subdomain_klass.aars_primary_key
          validate :subdomain_restrictions
          
          self.class_eval do
            default_scope { self.subdomain_klass.current ? where("#{self.subdomain_symbol}_id" => self.subdomain_klass.current.send(self.subdomain_klass.aars_primary_key)) : where('1 = 1') }
          end
          
          include InstanceMethods
        end
      end
    end

    def safe_sql_current_subdomain_primary_key
      id = self.subdomain_klass.current.send(self.subdomain_klass.aars_primary_key)
      case self.subdomain_klass.aars_primary_key_type
      when :integer then id.to_i
      when :uuid then id.to_s =~ RestrictedSubdomain::SAFE_UUID ? "'#{id}'" : "''"
      else raise "Unsupported column type '#{self.subdomain_klass.aars_primary_key_type}'"
      end
    end
    
    ##
    # Checks to see if the class has been restricted to a subdomain.
    #
    def restricted_to_subdomain?
      self.respond_to?(:subdomain_symbol) && self.respond_to?(:subdomain_klass)
    end
    
    module InstanceMethods
      private
      def subdomain_restrictions
        if !self.send("#{subdomain_symbol}_id?") and subdomain_klass.current
          self.send("#{subdomain_symbol}_id=", subdomain_klass.current.send(subdomain_klass.aars_primary_key))
        end
        if self.send("#{subdomain_symbol}_id").nil?
          self.errors.add(subdomain_symbol, 'is missing')
        end
      end
    end
  end
end

ActiveRecord::Base.send :extend, RestrictedSubdomain::Model
