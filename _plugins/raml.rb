require 'raml_parser'
require 'raml_parser/snippet_generator'
require_relative 'json'

module Jekyll

  module Helpers
    include Jekyll::JsonFilters

    def generate_free_type_pages(parent_link, site, base, dir, key_prefix, name_prefix, parent_key, obj, pages)
        json_attr_tbl_map(obj, parent_key).select { |row| row['xof'] }.each { |row|
        id = row['id']
        row['xof_items'].each { | xof_row |
          if xof_row['link_name']
            pages << FreeTypePage.new(parent_link, site, base, dir, key_prefix, "#{name_prefix}.#{id}", xof_row['id'], xof_row['raw_obj'], pages)
          end
        }
      }
    end

    def upcase_first(str)
      f = lambda { | fst | fst.upcase }
      transform_first(str, f)
    end

    def downcase_first(str)
      f = lambda { | fst | fst.downcase }
      transform_first(str, f)
    end

    def transform_first(str, f)
      if str.size > 1
        f.call(str[0]) + str[1..-1]
      elsif str.size == 1
        f.call(str[0])
      else
        str
      end
    end
  end

  class ApiResourcePage < Page
    include Helpers

    def initialize(site, base, dir, key_prefix, singular_rsrc_name, raml, raml_resource, raml_method, subpages)

      slugified = Jekyll::Utils::slugify("#{raml_method.method}-#{raml_resource.relative_uri}")

      # Qualify URI to tell apart the same method call against the same resource, 
      # which differ by request or response bodies.
      relative_uri = raml_resource.relative_uri
      uri_with_qualifier = relative_uri.split('/qual-')
      uri_without_qualifier = uri_with_qualifier[0]
      uri_qualifier = ''
      if uri_with_qualifier.length > 1
        relative_uri = uri_with_qualifier[0]              # retain only part before qualifier for relative uri
        uri_qualifier = "(#{uri_with_qualifier[1].gsub('-',' ')})"    # save off qualifier part, replace dashes

        # correct absolute URI for code examples
        raml_resource.absolute_uri = raml_resource.absolute_uri.split('/qual-')[0]

        # relativize display name, adjusting for qualifier
        if raml_resource.display_name == raml_resource.relative_uri
          raml_resource.display_name = relative_uri
        end

        slugified = Jekyll::Utils::slugify("#{raml_method.method}-#{relative_uri}-#{uri_qualifier}")
      end

      # Resolve any variables that are not resolved by native RAML parser -- a JIT correction, basically.
      # See: http://www.rubydoc.info/gems/raml_parser/0.2.5/
      resolve_is_query_parms(raml, raml_method)

      @site = site
      @base = base
      @dir = dir
      @name = slugified + '.html'

      self.process(@name)
      self.read_yaml(File.join(base, '_layouts'), 'resource.html')

      # establish collection type if this is a resource/method that returns a collection
      if (raml_method.method.upcase.include? 'GET') && (uri_without_qualifier =~ /.*\/(.+)s$/i)
        collection_type = to_formal_name($1)
      end
      # the base resource type is either the endpoint entry resource, or the resource of the
      # collection object being returned (e.g. /users = user, /users/{userId}/transfers = transfer)
      base_rsrc_type = collection_type ? collection_type : to_formal_name(singular_rsrc_name)

      self.data['key'] = key_prefix + slugified + '-information'
      self.data['title'] = raml_resource.display_name
      self.data['category'] = 'raml'
      self.data['subpage_link_prefix'] = "/#{dir}#{base_rsrc_type}"
      self.data['relative_uri'] = relative_uri
      self.data['uri_qualifier'] = uri_qualifier

      self.data['raml'] = RamlLiquidifyer.new(raml)
      self.data['raml_resource'] = RamlLiquidifyer.new(raml_resource)
      self.data['raml_method'] = RamlLiquidifyer.new(raml_method)

      snippet_generator = RamlParser::SnippetGenerator.new(raml)
      self.data['raml_snippets'] = [
        {
          'title' => 'CURL',
          'snippet' => begin
            snippet_generator.curl(raml_resource, raml_method.method.downcase)
          rescue
            ''
          end
        },
        {
          'title' => 'JavaScript',
          'snippet' => begin
            snippet_generator.javascript_vanilla(raml_resource, raml_method.method.downcase)
          rescue
            ''
          end
        },
        {
          'title' => 'Ruby',
          'snippet' => begin
            snippet_generator.ruby(raml_resource, raml_method.method.downcase)
          rescue
            ''
          end
        }
      ]

      uniq_prop_sets = get_method_schemas_uniq_property_sets(raml_method)
      uniq_prop_sets.each { |s|
        s.each_pair { |key, prop|
          resource_link = "/#{dir}resource-#{to_common_name(base_rsrc_type)}s.html"
          subname_prefix = base_rsrc_type
          generate_free_type_pages(resource_link, site, base, dir, key_prefix, subname_prefix, key, prop, subpages)
        }
      }
    end

    def to_formal_name(name)
      if name =~ /cert(s*)/
        "certificate" + $1
      else
        name
      end
    end

    def to_common_name(name)
      if name =~ /certificate(s*)/
        "cert" + $1
      else
        name
      end
    end

    # Resolves and adds method query parms included via "is" traits
    def resolve_is_query_parms(raml, raml_method)
      if raml_method.is
        raml_method.is.each_pair { |key, val|
          # find is trait in the gobal traits map
          if raml.traits[key]
            raml_method.is[key] = deep_copy(raml.traits[key])
            trait_node = raml_method.is[key]
            trait_node_hash = raml_method.is[key].value 
            resolve_trait_parms(trait_node_hash, val)
            # merge query parms included via is traits into existing query parms
            if trait_node_hash['queryParameters']
              qp = trait_node.hash('queryParameters').hash_values { |n| parse_named_parameter(n, false) }
              raml_method.query_parameters = raml_method.query_parameters.merge(qp)
            end
          end 
        }
      end
    end

    # This function will recursively enter a trait map and resolve references 
    # to trait parameters passed in from a resourceType template
    def resolve_trait_parms(t, p)
      if (t.is_a? Hash) && (p.is_a? Hash)
          t.each_pair{ |tk, tv|
            p.each_pair{ |pk, pv| 
              if(tv == ("<<#{pk}>>"))
                t[tk] = pv
              end
            }
            resolve_trait_parms(tv, p)
          }
      end
    end

    # Like the name says, make a deep copy of a reference
    def deep_copy(o)
      Marshal.load(Marshal.dump(o))
    end
    
    # Create RamlParser::Model::NamedParameter from node
    def parse_named_parameter(node, required_per_default)
      if node.value.is_a? Array
        node.mark_all(:unsupported)
        # named parameters with multiple types not supported
        return RamlParser::Model::NamedParameter.new(node.key)
      end

      node = node.or_default({})
      named_parameter = RamlParser::Model::NamedParameter.new(node.key)
      named_parameter.type = node.hash('type').or_default('string').value
      named_parameter.display_name = node.hash('displayName').or_default(named_parameter.name).value
      named_parameter.description = node.hash('description').value
      named_parameter.required = node.hash('required').or_default(required_per_default).value
      named_parameter.default = node.hash('default').value
      named_parameter.example = node.hash('example').value
      named_parameter.min_length = node.hash('minLength').value
      named_parameter.max_length = node.hash('maxLength').value
      named_parameter.minimum = node.hash('minimum').value
      named_parameter.maximum = node.hash('maximum').value
      named_parameter.repeat = node.hash('repeat').value
      named_parameter.enum = node.hash('enum').or_default([]).array_values { |n| n.value }
      named_parameter.pattern = node.hash('pattern').value
      named_parameter
    end

    def get_method_schemas_uniq_property_sets(raml_method)
      known_keys = []
      uniq_props = []
      get_method_schemas(raml_method).each {|schema|
        keys = json_keys(schema,'properties').sort
        if !(known_keys.include? keys)
          known_keys << keys
          uniq_props << json_field(schema, 'properties')
        end
      }
      uniq_props
    end

    def get_method_schemas(raml_method)
      schemas = []
      if raml_method.bodies
        schemas += get_schemas(raml_method.bodies.values)
      end
      if raml_method.responses
        raml_method.responses.values.each { |res|
          if res.bodies
            schemas += get_schemas(res.bodies.values)
          end
        }
      end
      schemas
    end

    def get_schemas(bodies)
      bodies.select {|b| b.media_type && (b.media_type.include? 'application/json') && b.schema}.map { |b| b.schema }
    end

  end

  class ApiResourcePageGenerator < Generator
    include Helpers

    def generate(site)
      site.config['raml'].each do |raml_config|
        path = File.join(site.source, raml_config['root_file'])
        result = RamlParser::Parser.parse_file_with_marks(path)
        raml = result[:root]
        not_used = result[:marks].select { |_,m| m != :used }
        not_used.each { |p,m| puts "#{m} #{p}" }

        subpages = []
        singular_rsrc_name = ''
        pages = raml.resources.map { |res|
          if res.display_name =~ /(^[A-Z]\w*)s$/i
            singular_rsrc_name = downcase_first($1)
          end
          res.methods.map { |_,meth|
            ApiResourcePage.new(site, site.source, raml_config['url_prefix'], raml_config['key_prefix'], singular_rsrc_name, raml, res, meth, subpages)
          }
        }
        site.pages += (pages + subpages).flatten
      end
    end
  end

  class RamlPage < Page
    def initialize(site, base, dir, key_prefix, raml_raw)
      @site = site
      @base = base
      @dir = dir
      @name = 'api.raml'

      self.process(@name)
      self.read_yaml(File.join(base, '_layouts'), 'api.raml')

      self.data['key'] = key_prefix + '-raml-file'
      self.data['searchable'] = false
      self.data['raml_raw'] = raml_raw
    end
  end

  class RamlPageGenerator < Generator
    def generate(site)
      site.config['raml'].each do |raml_config|
        path = File.join(site.source, raml_config['root_file'])
        raml_raw = RamlParser::YamlHelper.dump_yaml(RamlParser::YamlHelper.read_yaml(path))

        site.pages << RamlPage.new(site, site.source, raml_config['url_prefix'], raml_config['key_prefix'], raml_raw)
      end
    end
  end

  class FreeTypePage < Page
    include Helpers

    @@free_type_pages = []

    def initialize(parent_link, site, base, dir, key_prefix, name_prefix, obj_id, obj, pages)

      page_name = "#{name_prefix}.#{obj_id}"
      @@free_type_pages << page_name

      page_name_urlsafe = page_name.gsub('[i]','_i_')

      @site = site
      @base = base
      @dir = dir      
      @name = page_name_urlsafe + '.html'

      self.process(@name)
      self.read_yaml(File.join(base, '_layouts'), 'free-type.html')
      
      self.data['key'] = key_prefix + page_name + '-information'
      self.data['free_type_base_rsrc'] = parse_base(page_name)
      self.data['free_type_parent_rsrc'] = resolve_parent(name_prefix, self.data['free_type_base_rsrc'])
      self.data['free_type_id'] = obj_id
      free_type_rows = json_attr_tbl_map(obj, '')
      self.data['free_type_first_row'] = free_type_rows[0]
      self.data['free_type_last_rows'] = free_type_rows[1..-1]
      self.data['subpage_link_prefix'] = "/#{dir}#{page_name_urlsafe}"
      self.data['parent_link'] = parent_link

      subname_prefix = page_name
      generate_free_type_pages(parent_link, site, base, dir, key_prefix, subname_prefix, '', obj, pages)

    end

    def parse_base(page_name)
      base = page_name.split('.').first
      upcase_first(base)
    end

    def resolve_parent(name_prefix, free_type_base_rsrc)
      just_parent = remove_free_type_grandparent(name_prefix, free_type_base_rsrc)
      if just_parent != name_prefix
        upcase_first(just_parent)
      elsif just_parent =~ /^.+\.resources\[i\]$/
        upcase_first(free_type_base_rsrc)
      else
        upcase_first(just_parent)
      end
    end

    def remove_free_type_grandparent(name_prefix, free_type_base_rsrc)
      match_data = /(?<gp>.+)\.(?<p>.+)/.match(name_prefix)

      if match_data
        gp = match_data[:gp]
        p  = match_data[:p]

        if @@free_type_pages.include? gp
          if gp =~ /^.+\.resources\[i\]\..+$/
            free_type_base_rsrc + '.' + p
          else
            p
          end
        else
          remove_free_type_grandparent(gp, free_type_base_rsrc) + '.' + p
        end
      else
        name_prefix
      end
    end

  end

  class RamlLiquidifyer
    ACCESSOR_MAP = {
      RamlParser::Model::Root => %w(title base_uri version media_type schemas security_schemes base_uri_parameters resource_types traits secured_by documentation resources),
      RamlParser::Model::Resource => %w(absolute_uri relative_uri display_name description base_uri_parameters uri_parameters methods type is secured_by),
      RamlParser::Model::Method => %w(method description query_parameters responses bodies headers is secured_by),
      RamlParser::Model::Response => %w(status_code display_name description bodies headers),
      RamlParser::Model::Body => %w(media_type example schema form_parameters),
      RamlParser::Model::NamedParameter => %w(name type display_name description required default example min_length max_length minimum maximum repeat enum pattern),
      RamlParser::Model::Documentation => %w(title content),
      RamlParser::Model::SecurityScheme => %w(name type description described_by settings)
    }

    def initialize(obj)
      @obj = obj
    end

    def convert(node)
      if node == nil
        node
      elsif node == true or node == false
        node
      elsif node.is_a? String
        node
      elsif node.is_a? Integer
        node
      elsif node.is_a? Float
        node
      elsif node.is_a? Array
        node.map { |item| convert(item) }
      elsif node.is_a? Hash
        Hash[node.map { |key,value| [key, convert(value)] }]
      elsif ACCESSOR_MAP[node.class] != nil
        Hash[ACCESSOR_MAP[node.class].map { |name| [name, convert(node.send(name))] }]
      end
    end

    def to_liquid
      convert(@obj)
    end
  end

end
