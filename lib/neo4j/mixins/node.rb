module Neo4j

  
  class LuceneIndexOutOfSyncException < StandardError
    
  end

 
  #
  # Represent a node in the Neo4j space.
  # 
  # Is a wrapper around a Java neo node
  # 
  #
  module NodeMixin
    attr_reader :internal_node 

    extend TransactionalMixin
    

    # Initialize the the neo node for this instance.
    # Will create a new transaction if one is not already running.
    # If a block is given a new transaction will be created.
    # 
    # Does
    # * sets the neo property 'classname' to self.class.to_s
    # * creates a neo node java object (in @internal_node)
    #
    # :api: public
    def initialize(*args)
      # was a neo java node provided ?
      if args.length == 1 and args[0].kind_of?(org.neo4j.api.core.Node)
        Transaction.run {init_with_node(args[0])} unless Transaction.running?
        init_with_node(args[0])                   if Transaction.running?
      elsif block_given? 
        Transaction.run {init_without_node; yield self} unless Transaction.running?        
        begin init_without_node; yield self end         if Transaction.running?                
      else 
        Transaction.run {init_without_node} unless Transaction.running?        
        init_without_node                   if Transaction.running?                
      end
      
      # must call super with no arguments so that chaining of initialize method will work
      super() 
    end
    

    # Inits this node with the specified java neo node
    #
    # :api: private
    def init_with_node(node)
      @internal_node = node
      self.classname = self.class.to_s unless @internal_node.hasProperty("classname")
      $NEO_LOGGER.debug {"loading node '#{self.class.to_s}' node id #{@internal_node.getId()}"}
    end
    
    # Inits when no neo java node exists. Must create a new neo java node first.
    #
    # :api: private
    def init_without_node
      @internal_node = Neo4j.instance.create_node
      self.classname = self.class.to_s
      Neo4j.instance.ref_node.connect(self) 

      self.class.fire_event NodeCreatedEvent.new(self)      
      $NEO_LOGGER.debug {"created new node '#{self.class.to_s}' node id: #{@internal_node.getId()}"}        
    end
    
    
    # Sets a neo property on this node. This property does not have to be declared first.
    # If the value of the property is nil the property will be removed.
    #
    # Runs in a new transaction if there is not one already running,
    # otherwise it will run in the existing transaction.
    #
    # ==== Parameters
    # name<String>:: the name of the property to be set
    # value<Object>:: the value of the property to be set.
    #
    # ==== Example
    #   n = Node.new
    #   n.foo = 'hej'
    # 
    # :api: public
    def set_property(name, value)
      $NEO_LOGGER.debug{"set property '#{name}'='#{value}'"}      
      old_value = get_property(name)

      if value.nil?
        remove_property(name)
      elsif self.class.marshal?(name)
        @internal_node.set_property(name, Marshal.dump(value).to_java_bytes)
      else
        @internal_node.set_property(name, value)
      end

      if (name != 'classname')  # do not want events on internal properties
        event = PropertyChangedEvent.new(self, name.to_sym, old_value, value)
        self.class.fire_event(event)
      end
    end

    # Removes the property from this node.
    # For more information see JavaDoc PropertyContainer#removeProperty
    #
    # ==== Example
    #   a = Node.new
    #   a.set_property('foo',2)
    #   a.remove_property('foo')
    #   a.get_property('foo') # => nil
    #
    # ==== Returns
    # true if the property was removed, false otherwise
    #
    # :api: public
    def remove_property(name)
      !@internal_node.removeProperty(name).nil?
    end


    # Returns the value of the given neo property.
    #
    # ==== Returns
    # the value of the property or nil if the property does not exist
    #
    # :api: public
    def get_property(name)
      $NEO_LOGGER.debug{"get property '#{name}'"}
      
      return nil if ! property?(name)
      value = @internal_node.get_property(name.to_s)
      if self.class.marshal?(name)
        Marshal.load(String.from_java_bytes(value))
      else
        value
      end
    end


    # Checks if the given neo property exists.
    #
    # ==== Returns
    # true if the property exists
    #
    # :api: public
    def property?(name)
      @internal_node.has_property(name.to_s) unless @internal_node.nil?
    end


    # Creates a struct class containig all properties of this class.
    # This value object can be used from Ruby on Rails RESTful routing.
    #
    # ==== Example
    #
    # h = Person.value_object.new
    # h.name    # => nil
    # h.name='kalle'
    # h[:name]   # => 'kalle'
    #
    # ==== Returns
    # a value object struct
    #
    # :api: public
    def value_object
      vo = self.class.value_object.new
      vo._update(props)
      vo
    end

    #
    # Updates this node's properties by using the provided struct/hash.
    #
    # ==== Parameters
    # struct_or_hash<#each_pair>:: the key and value to be set
    #
    # ==== Returns
    # self
    #
    # :api: public
    def update(struct_or_hash)
      struct_or_hash.each_pair do |key,value|
        method = "#{key}=".to_sym
        self.send(method, value) if self.respond_to?(method)
      end
      self
    end


    # Returns an unique id
    # Calls getId on the neo node java object
    #
    # ==== Returns
    # Fixnum:: the unique neo id of the node.
    #
    # :api: public
    def neo_node_id
      @internal_node.getId()
    end


    # Same as neo_node_id but returns a String intead of a Fixnum.
    # Used by Ruby on Rails.
    #
    # :api: public
    def to_param
      neo_node_id.to_s
    end

    def eql?(o)
      o.kind_of?(NodeMixin) && o.internal_node == internal_node
    end
    
    def ==(o)
      eql?(o)
    end
    
    def hash
      internal_node.hashCode
    end
    
    # Returns a hash of all properties.
    #
    # ==== Returns
    # Hash:: property key and property value
    #
    # :api: public
    def props
      ret = {}
      iter = @internal_node.getPropertyKeys.iterator
      while (iter.hasNext) do
        key = iter.next
        ret[key] = @internal_node.getProperty(key)
      end
      ret
    end


    def lucene_index
      self.class.lucene_index
    end
    
    # Deletes this node.
    # Invoking any methods on this node after delete() has returned is invalid and may lead to unspecified behavior.
    # Runs in a new transaction if one is not already running.
    #
    # :api: public
    def delete
      self.class.fire_event(NodeDeletedEvent.new(self))
      relations.each {|r| r.delete}
      @internal_node.delete
      lucene_index.delete(neo_node_id)
    end
    
    # :api: private
    def classname
      get_property('classname')
    end

    # :api: private
    def classname=(value)
      set_property('classname', value)
    end
    

    # Returns a Neo4j::Relations::RelationTraverser object for accessing relations from and to this node.
    # The Neo4j::Relations::RelationTraverser is an Enumerable that returns Neo4j::RelationMixin objects.
    #
    # ==== See Also
    # * Neo4j::Relations::RelationTraverser
    # * Neo4j::RelationMixin
    #
    # ==== Example
    #
    #   person_node.relations.outgoing(:friends).each { ... }
    #
    # :api: public
    def relations
      Relations::RelationTraverser.new(@internal_node)
    end


    # Returns a Neo4j::Relations::NodeTraverser object for traversing nodes from and to this node.
    # The Neo4j::Relations::NodeTraverser is an Enumerable that returns Neo4j::NodeMixin objects.
    #
    # ==== See Also
    # Neo4j::Relations::NodeTraverser
    #
    # ==== Example
    #
    #   person_node.traverse.outgoing(:friends).each { ... }
    #
    # :api: public
    def traverse
      Relations::NodeTraverser.new(@internal_node)
    end

    
    # Mark this node to be reindex by lucene after the transaction finishes
    #
    # @api private
    def reindex
      Transaction.current.reindex(self)
    end

    # Reindex this node now
    #
    # @api private
    def reindex!
      doc = {:id => neo_node_id }
      self.class.index_updaters.each_value do |updater|
        updater.call(self, doc)
      end
      lucene_index << doc
    end

    
    transactional :property?, :set_property, :get_property, :remove_property, :delete


    
    #
    # Adds classmethods in the ClassMethods module
    #
    def self.included(c)
      # all subclasses share the same index, declared properties and index_updaters
      c.instance_eval do
        const_set(:ROOT_CLASS, self.to_s)
        const_set(:LUCENE_INDEX_PATH, "/" + self.to_s.gsub('::', '/'))
        const_set(:INDEX_UPDATERS, {})
        const_set(:INDEX_TRIGGERS, {})
        const_set(:RELATIONS_INFO, {})
        const_set(:PROPERTIES_INFO, {})
      end unless c.const_defined?(:ROOT_CLASS)
      
      c.extend ClassMethods
    end

    # --------------------------------------------------------------------------
    # NodeMixin class methods
    #
    module ClassMethods
    
      #
      # Access to class constants.
      # These properties are shared by the class and its siblings.
      # For example that means that we can specify properties for a parent
      # class and the child classes will 'inherit' those properties.
      #
      
      # :api: private
      def root_class
        self::ROOT_CLASS
      end

      #
      # :api: private
      def lucene_index
        Lucene::Index.new(self::LUCENE_INDEX_PATH)
      end
        
      #
      # :api: private
      def index_updaters
        self::INDEX_UPDATERS
      end

      # :api: private
      def index_triggers
        self::INDEX_TRIGGERS
      end

      
      # Contains information of all relationships, name, type, and multiplicity
      #
      # :api: private
      def relations_info
        self::RELATIONS_INFO
      end

      # :api: private
      def properties_info
        self::PROPERTIES_INFO
      end

     
      # ------------------------------------------------------------------------
      # Event index_updater

      #
      # @api private
      def fire_event(event)
        index_triggers.each_value {|trigger| trigger.call(event.node, event)}
        Transaction.current.broadcast_event(event)
      end
      
      
      # ------------------------------------------------------------------------


      # Generates accessor method and sets configuration for Neo4j node properties.
      # The generated accessor is a simple wrapper around the #set_property and
      # #get_property methods.
      #
      # If a property is set to nil the property will be removed.
      #
      # ==== Configuration
      # By setting the :type configuration parameter to 'Object' makes
      # it possible to marshal any ruby object.
      #
      # If no type is provided the only the native Neo4j property types are allowed:
      # * TrueClass, FalseClass
      # * String
      # * Fixnum
      # * Float
      # * Boolean
      #
      # ==== Parameters
      # props<Array,Hash>:: a variable length arguments or a hash, see example below
      #
      # ==== Example
      #   class Baaz; end
      #
      #   class Foo
      #     include Neo4j::NodeMixin
      #     property name, city # can set several properties in one go
      #     property bar, :type => Object # allow serialization of any ruby object
      #   end
      #
      #   f = Foo.new
      #   f.bar = Baaz.new
      #
      # :api: public
      def property(*props)
        if props.size == 2 and props[1].kind_of?(Hash)
          props[1].each_pair do |key,value|
            pname = props[0].to_sym
            properties_info[pname] ||= {}
            properties_info[pname][key] = value
          end
          props = props[0..0]
        end

        props.each do |prop|
          pname = prop.to_sym
          properties_info[pname] ||= {}
          properties_info[pname][:defined] = true
        
          define_method(pname) do
            get_property(pname.to_s)
          end

          name = (pname.to_s() +"=").to_sym
          define_method(name) do |value|
            set_property(pname.to_s, value)
          end
        end
      end

      # Returns true if the given property name should be marshalled.
      # All properties that has a type will be marshalled.
      #
      # ===== Example
      #   class Foo
      #     include Neo4j::NodeMixin
      #     property :name
      #     property :since, :type => Date
      #   end
      #   Foo.marshal?(:since) => true
      #   Foo.marshal?(:name) => false
      #
      # ==== Returns
      # true if the property will be marshalled, false otherwise
      #
      # :api: public
      def marshal?(prop_name)
        return false if properties_info[prop_name.to_sym].nil?
        return false if properties_info[prop_name.to_sym][:type].nil?
        return true
      end


      # Returns true if the given property name has been defined with the class
      # method property or properties.
      #
      # Notice that the node may have properties that has not been declared.
      # It is always possible to set an undeclared property on a node.
      #
      # ==== Returns
      # true or false
      #
      # :api: public
      def property?(prop_name)
        return false if properties_info[prop_name.to_sym].nil?
        properties_info[prop_name.to_sym][:defined] == true
      end


      # Creates a struct class containig all properties of this class.
      #
      # ==== Example
      #
      # h = Person.value_object.new
      # h.name    # => nil
      # h.name='kalle'
      # h[:name]   # => 'kalle'
      #
      # ==== Returns
      # Struct
      #
      # :api: public
      def value_object
        @value_class ||= create_value_class
      end

      # Index a property or a relationship.
      # If the rel_prop arg contains a '.' then it will index the relationship.
      # For example "friends.name" will index each node with property name in the relationship friends.
      # For example "name" will index the name property of this NodeMixin class.
      #
      # ==== Example
      #   class Person
      #     include Neo4j::NodeMixin
      #     property :name
      #     index :name
      #   end
      #
      # :api: public     
      def index(*rel_type_props)
        if rel_type_props.size == 2 and rel_type_props[1].kind_of?(Hash)
          rel_type_props[1].each_pair do |key,value|
            idx = rel_type_props[0]
            lucene_index.field_infos[idx.to_sym][key] = value
          end
          rel_type_props = rel_type_props[0..0]
        end
        rel_type_props.each do |rel_type_prop|
          rel_type, prop = rel_type_prop.to_s.split('.')
          index_property(rel_type) if prop.nil?
          index_relation(rel_type_prop, rel_type, prop) unless prop.nil?
        end
      end


      # Remote one or more specified indexes.
      # This indexes will not be updated anymore, old indexes will still exist
      # until the update_index method is called.
      #
      # :api: public
      def remove_index(*keys)
        keys.each do |key|
          index_updaters.delete key.to_s
          index_triggers.delete key.to_s
        end
      end


      # Traverse all nodes and update the lucene index.
      # Can be used for example if it is neccessarly to change the index on a class
      #
      # :api: public
      def update_index
        all.nodes.each do |n|
          n.reindex!
        end
      end
      
      # :api: private
      def index_property(prop)
        updater = lambda do |node, doc|
          doc[prop] = node.send(prop)
        end
        index_updaters[prop] = updater
        
        trigger = lambda do |node, event|
          node.reindex if Neo4j::PropertyChangedEvent.trigger?(event, :property, prop)
        end
        index_triggers[prop] = trigger
      end
      
      
      # :api: private
      def index_relation(index_key, rel_type, prop)
        clazz = relations_info[rel_type.to_sym][:class]
        
        type = relations_info[rel_type.to_sym][:type]  # this or the other node we index ?
        rel_type = type.to_sym unless type.nil?

        # updater - called when index needs to be updated
        updater = lambda do |my_node, doc|
          values = []
          relations = my_node.relations.both(rel_type).nodes
          relations.each {|other_node| values << other_node.send(prop)}
          doc[index_key] = values
        end
        index_updaters[index_key] = updater
      
        # trigger - knows if an index needs to be updated
        trigger = lambda do |other_node, event|
          if (Neo4j::PropertyChangedEvent.trigger?(event, :property, prop) or
                Neo4j::RelationshipEvent.trigger?(event) or
                Neo4j::NodeLifecycleEvent.trigger?(event))
            relations = other_node.relations.both(rel_type).nodes
            relations.each {|r| r.send(:reindex)}
          end
        end
        clazz.index_triggers[index_key] = trigger
      end
      
      # Specifies a relationship between two node classes.
      #
      # ==== Example
      #   class Order
      #      has_one(:customer).of_class(Customer)
      #   end
      #
      # :api: public
      def has_one(rel_type)

        module_eval(%Q{def #{rel_type}=(value)
                        r = Relations::HasN.new(self,'#{rel_type.to_s}')
                        r << value
                    end},  __FILE__, __LINE__)
        
        module_eval(%Q{def #{rel_type}
                        r = Relations::HasN.new(self,'#{rel_type.to_s}')
                        r.to_a[0]
                    end},  __FILE__, __LINE__)
        relations_info[rel_type] = Relations::RelationInfo.new
      end

      

      # Specifies a relationship between two node classes.
      #
      # ==== Example
      #   class Order
      #      has_n(:order_lines).to(Product).relation(OrderLine)
      #   end
      #
      # :api: public
      def has_n(rel_type)
        module_eval(%Q{def #{rel_type}(&block)
                        Relations::HasN.new(self,'#{rel_type.to_s}', &block)
                    end},  __FILE__, __LINE__)
        relations_info[rel_type] = Relations::RelationInfo.new
      end


      # Returns node instances of this class.
      #
      # :api: public
      def all
        ref = Neo4j.instance.ref_node
        ref.relations.outgoing(root_class)
      end


      # Creates a new outgoing relation.
      # 
      # :api: private
      def new_relation(rel_name, internal_relation)
        relations_info[rel_name.to_sym][:relation].new(internal_relation) # internal_relation is a java neo object
      end
      
     
      
      # Finds all nodes of this type (and ancestors of this type) having
      # the specified property values.
      # See the lucene module for more information how to do a query.
      #
      # ==== Example
      #   MyNode.find(:name => 'foo', :company => 'bar')
      #
      # Or using a DSL query (experimental)
      #   MyNode.find{(name == 'foo') & (company == 'bar')}
      #
      # ==== Returns
      # Neo4j::SearchResult
      #
      # :api: public
      def find(query=nil, &block)
        SearchResult.new lucene_index, query, &block
      end


      # Creates a new value object class (a Struct) represeting this class.
      #
      # The struct will have the Ruby on Rails method: model_name and
      # new_record? so that it can be used for restful routing.
      #
      # TODO: if the DynamicMixin is used it should return somthing more flexible
      # since we do not know which property a class has.
      # 
      # @api private
      def create_value_class
        # the name of the class we want to create
        name = "#{self.to_s}ValueObject".gsub("::", '_')

        # remove previous class if exists
        Neo4j.instance_eval do
          remove_const name
        end if Neo4j.const_defined?(name)

        # get the properties we want in the new class
        props = self.properties_info.keys.map{|k| ":#{k}"}.join(',')
        Neo4j.module_eval %Q[class #{name} < Struct.new(#{props}); end]

        # get reference to the new class
        clazz = Neo4j.const_get(name)

        # make it more Ruby on Rails friendly - try adding model_name method
        if self.respond_to?(:model_name)
          model = self.model_name.clone
          (class << clazz; self; end).instance_eval do
            define_method(:model_name) {model}
          end
        end

        # by calling the _update method we change the state of the struct
        # so that new_record returns false - Ruby on Rails
        clazz.instance_eval do
          define_method(:_update) do |hash|
            @_updated = true
            hash.each_pair {|key,value| self[key.to_sym] = value if members.include?(key.to_s) }
          end
          define_method(:new_record?) { ! defined? @_updated }
        end

        clazz
      end

    end
  end
end
