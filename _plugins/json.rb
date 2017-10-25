require 'json'

module Jekyll
  module JsonFilters
    # return the key names (one level deep) inside the property attribute

    # FMJ - 20160310
    # raise an exception here when the JSON input does not include the property
    # Is it possible to ignore such errors? The build failed becuase some JSON
    # schemas did not include "properties".
    def json_keys(input, property)
      begin
        JSON.parse(input)[property].keys unless input.nil?
      rescue
        $stderr.print "JSON: " + JSON.pretty_generate(input)
        $stderr.print "Does not define property: " + property
        raise
      end
    end

    # return the value of property attribute related to input
    def json_field(input, property)
      JSON.parse(input)[property] unless input.nil?
    end

    # Gives an attribute table mapping, as an array of rows
    # where each row contains a hash with keys: id, type, description
    def json_attr_tbl_map(att, id)
      json_attr_tbl_map_recursive(att, id, [])
    end

    # All methods that follow will be made private: not accessible for outside objects.
    private 

    # Gives one row for attribute, represented as hash with various information relevant to the attribute
    def json_attr_row(att, id, *additional)
      xof = json_xof(att)
      meta = additional.first || {}
      {
        'id' => id,
        'raw_obj' => att,
        'type' => json_type_show(att),
        'enum' => att['enum'],
        'format' => att['format'],
        'pattern' => att['pattern'],
        'description' => att['description'],
        'link_name' => meta['link_name'],
        'xof' => xof,
        'xof_literate' => (json_xof_literate(xof) if xof),
        'xof_items' => (json_xof_items(att, id) if xof) 
      }
    end

    # Will recursively add rows for the table mapping of a JSON attribute,
    # adding a new row for each embedded attribute it finds
    def json_attr_tbl_map_recursive(att, id, rows)
      if att.is_a? Hash
        rows.push(json_attr_row(att, id))
        na = json_nested_attributes(att)
        if na
          if na['type'] == 'array' 
            json_attr_tbl_map_recursive(na['items'], id + '[i]' , rows) # id.[i] 
          else
            na.each_pair { |k, v|
              prefix = (id.empty?) ? id : "#{id}."  
              json_attr_tbl_map_recursive(v, prefix + k, rows) # id.<key>
            }      
          end
        end  
      end
      rows
    end

    # Gives nested attributes of JSON object
    def json_nested_attributes(obj)
      # conditions to check for nested object "potential"
      cond1 = obj['type'] == 'object'
      cond2 = obj['enum']
      cond3 = obj['type'] =~ /string|boolean|integer/
      cond4 = obj['type'] == 'array' && !obj['items']

       # return properties if they exist, or self as nested object
      if cond1 || !(cond2 || cond3 || cond4)
        if obj['properties'] 
          obj['properties'] 
        else
          obj 
        end 
      end
    end

    # Detects if JSON object is an "anyOf", "allOf", "oneOf" array type
    def json_xof(obj)
      if obj.is_a? Hash
        ('anyOf' if obj['anyOf']) || 
        ('oneOf' if obj['oneOf']) || 
        ('allOf' if obj['allOf'])
      end  
    end

    def json_xof_literate(xof)
      "#{xof[0..2].capitalize} #{xof[3..xof.size].downcase}"
    end

    # Creates a hash of id => json_attr_row for the types represented by a given nested xOf type
    def json_xof_items(obj, parent_id)
      xof = json_xof(obj)
      
      if xof
        i = 0
        xof_items = []

        obj[xof].each { | item |
          meta = {}
          i += 1
          if item['type'] == 'object' && item['required'].to_a.include?('type') # named complex type case
            props = item['properties']
            if props.to_h['type'].is_a?(Hash) && props['type']['enum'].to_a.size == 1
              id = props['type']['enum'].first
              meta['link_name'] = id
            end
          elsif item['type'] =~ /string|boolean|integer/ # primitive type case
            id = "primitive.#{i}"   
          end

          if id == nil # anyonymous complex type case
            id = "#{parent_id}.#{i}"
            meta['link_name'] = id
          end
          xof_items << json_attr_row(item, id, meta)
        }
        xof_items
      end
    end

    # Gives type to be shown for JSON object
    def json_type_show(obj)
      if obj.is_a? Hash
        if obj['type']
          obj['type']
        elsif json_nested_attributes(obj) && !json_xof(obj)
          'object'
        else
          json_xof(obj)  
        end
      end 
    end

  end
end
Liquid::Template.register_filter(Jekyll::JsonFilters)
